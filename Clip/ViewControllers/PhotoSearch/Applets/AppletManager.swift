//
//  AppletManager.swift
//  clipper
//

import Foundation
import Photos

enum AppletManagerError: LocalizedError {
    case clipModelNotReady
    case vlmNotDownloaded

    var errorDescription: String? {
        switch self {
        case .clipModelNotReady:
            return "The photo-search model isn't ready. Open Setup and download/select a model first."
        case .vlmNotDownloaded:
            return "Applets need a language model. Open Setup and download a VLM model first."
        }
    }
}

/// App-side coordinator for the Applets UI: lists/deletes applets and creates a new
/// one, backfilling it against the already-indexed photos so its count reflects
/// existing matches immediately. Backfill runs the same two-step check (CLIP gate →
/// VLM confirm) but records matches directly, so no notifications fire for
/// historical photos — only future captures notify.
@MainActor
final class AppletManager {

    private let context: PhotoSearchContext
    private let assetSource: PhotoAssetSource

    init(context: PhotoSearchContext, assetSource: PhotoAssetSource = PhotoKitAssetSource()) {
        self.context = context
        self.assetSource = assetSource
    }

    func list() -> [Applet] {
        (try? context.appletStore.list()) ?? []
    }

    func delete(_ applet: Applet) {
        try? context.appletStore.delete(id: applet.id)
    }

    /// Updates an existing applet's editable fields (name, notify). Does not
    /// re-backfill (the query is fixed once created).
    func update(_ applet: Applet) async throws {
        try context.appletStore.upsert(applet)
        if applet.notifyOnCapture {
            await requestNotificationAuthorization()
        }
    }

    /// Creates an applet and backfills it against the existing index, reporting
    /// 0...1 progress. Returns the applet with its seeded capture count.
    func create(
        query: String,
        name: String,
        notifyOnCapture: Bool,
        threshold: Double = Applet.defaultThreshold,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> Applet {
        guard let clipEngine = context.makeEngine() else { throw AppletManagerError.clipModelNotReady }
        guard let vlmEngine = context.makeVLMEngine() else { throw AppletManagerError.vlmNotDownloaded }

        // Make the selected CLIP model available to the background ingest extension
        // (bundled models live in the app bundle, which the extension can't see).
        context.modelManager.stageBundledModelInSharedContainer(context.modelStore.selectedModel)

        // Precompute the query embedding so the background ingest extension can run
        // the cosine gate without the CLIP text encoder/tokenizer.
        let modelIdentifier = context.modelStore.selectedModel.rawValue
        let queryEmbedding = try await clipEngine.textEmbedding(for: query)

        let applet = Applet(
            name: name.isEmpty ? query : name,
            query: query,
            createdAt: Date(),
            notifyOnCapture: notifyOnCapture,
            threshold: threshold,
            queryEmbedding: queryEmbedding,
            queryEmbeddingModelIdentifier: modelIdentifier
        )
        try context.appletStore.upsert(applet)
        if notifyOnCapture {
            await requestNotificationAuthorization()
        }
        enableBackgroundIngest()

        guard let index = try? context.indexStore.load(), !index.entries.isEmpty else {
            await vlmEngine.unload()
            onProgress(1)
            return refreshed(applet)
        }

        let imageInputSize = context.modelStore.selectedModel.imageInputSize
        let total = index.entries.count

        for (offset, entry) in index.entries.enumerated() {
            if queryEmbedding.count == entry.embedding.count {
                let similarity = Self.cosine(queryEmbedding, entry.embedding)
                if Double(similarity) >= threshold,
                   let image = await assetSource.loadImage(
                       localIdentifier: entry.localIdentifier, targetSize: imageInputSize
                   ),
                   (try? await vlmEngine.contains(image: image, query: query)) == true {
                    try? context.appletStore.recordMatch(appletID: applet.id, assetID: entry.localIdentifier)
                }
            }
            onProgress(Double(offset + 1) / Double(total))
        }

        await vlmEngine.unload()
        return refreshed(applet)
    }

    private func requestNotificationAuthorization() async {
        await context.appletNotificationManager.requestAuthorizationIfNeeded()
    }

    /// Enables PhotoKit's background-upload extension so the system wakes our
    /// extension to process new photos while the app is closed. Best-effort:
    /// requires full photo-library access and iOS 26.1+. Repeating it is harmless.
    private func enableBackgroundIngest() {
        if #available(iOS 26.1, *) {
            // The background-upload extension is only eligible with full library
            // access; with limited/denied access the API fails with a generic error.
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized else {
                context.logger.info(
                    "Skipping background ingest: needs full photo access (status \(status.rawValue)); foreground ingest still runs while the app is open"
                )
                return
            }
            do {
                try PHPhotoLibrary.shared().setUploadJobExtensionEnabled(true)
            } catch {
                context.logger.error("Couldn't enable background photo ingest: \(error)")
            }
        }
    }

    private func refreshed(_ applet: Applet) -> Applet {
        (try? context.appletStore.list())?.first { $0.id == applet.id } ?? applet
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }
}
