//
//  MediaIntentHandoff.swift
//  Luna
//
//  The media-kind body of the Action Button intents' download handoff —
//  compiled only into media-handling app targets (Downloader + the central
//  Luna app; excluded from the others via the synchronized group's membership
//  exceptions). Their `KindWiring` variants call `install()`, which fills
//  `ActionButtonIntentSupport.mediaHandoff`; in article/product-only apps the
//  seam stays nil and the intents return no media, matching the gate that only
//  media apps hand off.
//

import AppIntents
import LunaMediaDownload
import LunaModels
import LunaStorage
import Foundation
import UniformTypeIdentifiers

enum MediaIntentHandoff {

    enum MediaHandoffError: Error, CustomLocalizedStringResourceConvertible {
        case insufficientStorage(String)
        /// The save landed but its media didn't: nothing was downloaded and no
        /// transfer is running. Reported so a Shortcut can never exit with
        /// silent success and an empty library.
        case downloadFailed(message: String?)
        /// Photos add-authorization was refused for a sibling-app-owned save.
        case notAuthorized

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .insufficientStorage(let message): return "\(message)"
            case .downloadFailed(let message):
                guard let message, !message.isEmpty else {
                    return L10n.resource("Luna saved the link but couldn't download its media.")
                }
                return "\(message)"
            case .notAuthorized:
                return L10n.resource("Luna needs permission to save media to your photo library.")
            }
        }

        /// Maps a start result that reported no running transfer into the error
        /// the intent throws. `isDownloadHandled` results never reach this.
        init(startResult: LiveMediaDownloadStartResult) {
            switch startResult {
            case .notAuthorized: self = .notAuthorized
            case let .failed(message): self = .downloadFailed(message: message)
            case .unsupported, .started, .alreadyDownloaded, .deferredUntilWiFi:
                self = .downloadFailed(message: nil)
            }
        }
    }

    static func install() {
        ActionButtonIntentSupport.mediaPreparation = { urlString in
            try await prepareMediaIfNeeded(for: urlString)
        }
        ActionButtonIntentSupport.mediaHandoff = { urlString, checkpoint, foreground in
            try await downloadMediaIfNeeded(
                for: urlString, checkpoint: checkpoint, foreground: foreground)
        }
    }

    /// Completes every deterministic, non-transfer step in the normal Provide
    /// Context intent: local-file reuse, asset resolution/redirects, HEAD size,
    /// and storage validation. The resulting checkpoint is opaque to Shortcuts
    /// and lets Save begin with byte progress from its first download update.
    private static func prepareMediaIfNeeded(
        for urlString: String
    ) async throws -> ActionButtonIntentSupport.MediaPreparation {
        guard MediaAutoDownloader.shouldStartDownloaderIntentDownload(
            forURLString: urlString)
        else {
            SharedDiagnosticLog.record(
                "intent media preflight skipped: handlesMedia=\(MediaAutoDownloader.isRunningInDownloader), supported=\(MediaDownloadablePlatform.supports(urlString))",
                category: "media-download")
            return .none
        }
        if let existing = SavedMediaStore.shared.existingDownloadedItem(
            forURLString: urlString),
           let media = await MediaAutoDownloader.exportFile(from: existing) {
            return .completed(intentFile(for: media))
        }
        guard let sourceURL = URL(string: urlString),
              let inspection = await MediaDownloadPreflight.inspect(sourceURL: sourceURL)
        else { return .download(nil) }
        if let error = MediaDownloadPreflight.storageError(for: inspection) {
            throw MediaHandoffError.insufficientStorage(error.message)
        }
        return .download(IntentMediaCheckpoint(
            asset: inspection.asset,
            expectedByteCount: inspection.expectedByteCount))
    }

    /// SaveIntent's media handoff for both a prepared checkpoint and the
    /// screenshot/search path. `foreground` is invoked only
    /// when a first read/write Photos authorization prompt needs a visible host.
    private static func downloadMediaIfNeeded(
        for urlString: String,
        checkpoint: IntentMediaCheckpoint?,
        foreground: () async -> Void
    ) async throws -> IntentFile? {
        guard MediaAutoDownloader.shouldStartDownloaderIntentDownload(
            forURLString: urlString)
        else {
            SharedDiagnosticLog.record(
                "intent media handoff skipped: handlesMedia=\(MediaAutoDownloader.isRunningInDownloader), supported=\(MediaDownloadablePlatform.supports(urlString))",
                category: "media-download")
            return nil
        }
        if DownloaderIntentPhotoPermission.requiresForegroundRequest {
            await foreground()
        }
        let photosAuthorized = await DownloaderIntentPhotoPermission.requestIfNeeded()
        if let existing = SavedMediaStore.shared.existingDownloadedItem(
               forURLString: urlString) {
            let media = await MediaAutoDownloader.exportFile(from: existing)
            return media.map { intentFile(for: $0) }
        }
        let inspection: MediaDownloadInspection?
        if let checkpoint {
            inspection = MediaDownloadInspection(
                asset: checkpoint.asset,
                expectedByteCount: checkpoint.expectedByteCount)
        } else if let sourceURL = URL(string: urlString) {
            inspection = await MediaDownloadPreflight.inspect(sourceURL: sourceURL)
        } else {
            inspection = nil
        }
        if let inspection {
            if let error = MediaDownloadPreflight.storageError(for: inspection) {
                throw MediaHandoffError.insufficientStorage(error.message)
            }
            ActionButtonIntentSupport.byteProgress?(0, inspection.expectedByteCount)
            guard IntentMediaDownloadPolicy.shouldAwait(
                expectedByteCount: inspection.expectedByteCount)
            else {
                try await startInBackground(
                    for: urlString,
                    reason: "size, bytes=\(inspection.expectedByteCount.map(String.init) ?? "unknown")",
                    photosAuthorized: photosAuthorized)
                return nil
            }
            // The AWAITED leg is the one the system's intent progress UI covers
            // end to end (the intent stays alive for the whole transfer), so
            // prefer it and suppress Luna's own Live Activity for its duration.
            // The background leg below keeps ours, because the system's UI ends
            // when the intent returns and that transfer outlives it.
            let result = await LiveMediaDownloadManager.$systemProvidesProgressUI.withValue(
                CaptureIntentExtendedRuntime.isAvailable
            ) {
                await MediaAutoDownloader.downloadForDownloaderIntentAwaiting(
                    forURLString: urlString,
                    onByteProgress: { received, expected in
                        // Real bytes, so the system's progress UI counts actual
                        // MB instead of a heartbeat estimate.
                        ActionButtonIntentSupport.byteProgress?(received, expected)
                    })
            }
            SharedDiagnosticLog.record(
                "intent media handoff: synchronous=true, bytes=\(inspection.expectedByteCount.map(String.init) ?? "unknown"), result=\(result), systemProgressUI=\(CaptureIntentExtendedRuntime.isAvailable), photosAuthorized=\(photosAuthorized)",
                category: "media-download")
            switch result {
            case let .completed(media): return intentFile(for: media)
            case .handledWithoutFile: return nil
            case let .failed(message):
                // A user cancelling from the system's progress UI (or the system
                // reclaiming the runtime) cancels this task — a dismissal, not a
                // failure worth an error dialog. The transfer itself is durable
                // and keeps going, so hand the progress UI back to Luna's own
                // Live Activity on the way out: we suppressed it above precisely
                // because the system's was showing, and that one is now gone.
                if Task.isCancelled {
                    await LiveMediaDownloadManager.shared.resumeOwnProgressUI(
                        forSourceURLString: urlString)
                    return nil
                }
                throw MediaHandoffError.downloadFailed(message: message)
            }
        } else {
            try await startInBackground(
                for: urlString, reason: "size unavailable", photosAuthorized: photosAuthorized)
            return nil
        }
    }

    /// Hands the transfer to the durable background engine, throwing when it
    /// reports that nothing is downloading and nothing will be. A deferred
    /// (Wi-Fi-only) or already-downloaded result is a legitimate no-file return.
    private static func startInBackground(
        for urlString: String, reason: String, photosAuthorized: Bool
    ) async throws {
        let result = await MediaAutoDownloader.startDownloaderIntentDownload(
            forURLString: urlString)
        SharedDiagnosticLog.record(
            "intent media handoff: synchronous=false, reason=\(reason), result=\(result), photosAuthorized=\(photosAuthorized)",
            category: "media-download")
        guard result.isDownloadHandled else {
            throw MediaHandoffError(startResult: result)
        }
    }

    private static func intentFile(for media: DownloadedMedia) -> IntentFile {
        let type = UTType(filenameExtension: media.fileURL.pathExtension)
            ?? (media.kind == .video ? .mpeg4Movie : .image)
        return IntentFile(
            fileURL: media.fileURL,
            filename: media.fileURL.lastPathComponent,
            type: type)
    }
}
