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

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .insufficientStorage(let message): return "\(message)"
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
                let started = await MediaAutoDownloader.startDownloaderIntentDownload(
                    forURLString: urlString)
                SharedDiagnosticLog.record(
                    "intent media handoff: synchronous=false, reason=size, bytes=\(inspection.expectedByteCount.map(String.init) ?? "unknown"), started=\(started), photosAuthorized=\(photosAuthorized)",
                    category: "media-download")
                return nil
            }
            let media = await MediaAutoDownloader.downloadForDownloaderIntentAwaiting(
                forURLString: urlString)
            SharedDiagnosticLog.record(
                "intent media handoff: synchronous=true, bytes=\(inspection.expectedByteCount.map(String.init) ?? "unknown"), completed=\(media != nil), photosAuthorized=\(photosAuthorized)",
                category: "media-download")
            return media.map { intentFile(for: $0) }
        } else {
            let started = await MediaAutoDownloader.startDownloaderIntentDownload(
                forURLString: urlString)
            SharedDiagnosticLog.record(
                "intent media handoff: synchronous=false, started=\(started), photosAuthorized=\(photosAuthorized)",
                category: "media-download")
            return nil
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
