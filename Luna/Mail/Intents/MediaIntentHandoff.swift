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
                    return "Luna saved the link but couldn't download its media."
                }
                return "\(message)"
            case .notAuthorized:
                return "Luna needs permission to save media to your photo library."
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
        ActionButtonIntentSupport.mediaHandoff = { urlString, foreground in
            try await downloadMediaIfNeeded(for: urlString, foreground: foreground)
        }
    }

    /// One media handoff shared by ProvideContext's completed Safari fast path
    /// and SaveIntent's screenshot/search path. `foreground` is invoked only
    /// when a first read/write Photos authorization prompt needs a visible host.
    private static func downloadMediaIfNeeded(
        for urlString: String,
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
        if AppIntentSettings.returnsMediaToShortcuts,
           let existing = SavedMediaStore.shared.existingDownloadedItem(
               forURLString: urlString) {
            let media = await MediaAutoDownloader.exportFile(from: existing)
            return media.map { intentFile(for: $0) }
        }
        if AppIntentSettings.returnsMediaToShortcuts,
           let sourceURL = URL(string: urlString),
           let inspection = await MediaDownloadPreflight.inspect(sourceURL: sourceURL) {
            if let error = MediaDownloadPreflight.storageError(for: inspection) {
                throw MediaHandoffError.insufficientStorage(error.message)
            }
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
                IntentExtendedRuntime.providesSystemProgressUI
            ) {
                await MediaAutoDownloader.downloadForDownloaderIntentAwaiting(
                    forURLString: urlString)
            }
            SharedDiagnosticLog.record(
                "intent media handoff: synchronous=true, bytes=\(inspection.expectedByteCount.map(String.init) ?? "unknown"), result=\(result), systemProgressUI=\(IntentExtendedRuntime.providesSystemProgressUI), photosAuthorized=\(photosAuthorized)",
                category: "media-download")
            switch result {
            case let .completed(media): return intentFile(for: media)
            case .handledWithoutFile: return nil
            case let .failed(message):
                // A user cancelling from the system's progress UI cancels this
                // task — that's a dismissal, not a failure worth an error dialog.
                if Task.isCancelled { return nil }
                throw MediaHandoffError.downloadFailed(message: message)
            }
        } else {
            try await startInBackground(
                for: urlString, reason: "setting", photosAuthorized: photosAuthorized)
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
