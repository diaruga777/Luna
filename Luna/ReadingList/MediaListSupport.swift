//
//  MediaListSupport.swift
//  Luna
//
//  Media-kind implementation of `MediaListSupporting` — compiled only into
//  media-handling app targets (Downloader + the central Luna app; excluded from
//  the others via the synchronized group's membership exceptions) and installed
//  by their `KindWiring` variants.
//

import LunaDesignSystem
import LunaMediaDownload
import LunaModels
import LunaPlatforms
import LunaReadingListUI
import LunaStorage
import LunaURLClassification
import UIKit

final class MediaListSupport: MediaListSupporting {

    private let photoSaver = PhotoLibrarySaver()

    /// The launch ladder for a platform item: native app → in-app embed → in-app browser.
    func openPlatformItem(
        _ item: ReadingListItem, platform: ContentPlatform, from presenter: UIViewController
    ) {
        guard let module = PlatformRegistry.shared.module(for: platform) else { return }

        if let appURL = module.appDeepLink(for: item), UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL) { success in
                if success { ReadingListStore.shared.markReadState(.read, for: item.id) }
            }
            return
        }
        if let embed = module.embed(for: item) {
            presenter.present(PlatformEmbedViewController(embed: embed, itemID: item.id), animated: true)
            return
        }
        InAppBrowser.present(urlString: item.urlString, from: presenter)
    }

    func logoThumbnail(for platform: ContentPlatform) -> ReadingListItemCell.Thumbnail? {
        guard let module = PlatformRegistry.shared.module(for: platform) else { return nil }
        return .logo(assetName: platform.logoAssetName, glyph: module.glyphSymbolName)
    }

    /// Platform items show a logical container, never the bare host.
    func subtitleLeadingLabel(for item: ReadingListItem) -> String? {
        guard let platform = item.contentPlatform,
              let module = PlatformRegistry.shared.module(for: platform) else { return nil }
        return module.subtitle(for: item) ?? platform.displayName
    }

    /// X / Instagram / TikTok posts: whether the post's media can be downloaded
    /// (audio-only direct URLs can't be saved to Photos).
    func canSaveMediaToPhotos(urlString: String) -> Bool {
        MediaDownloadablePlatform.supports(urlString)
            && DirectMediaURL.kind(for: urlString) != .audio
    }

    /// Hands the first media item of an X/Instagram/TikTok/Facebook post to the
    /// background media downloader (or, on the Downloader surface, saves the
    /// already-downloaded local media). The Live Activity/background URLSession
    /// own the durable transfer; the pill is only immediate in-app feedback.
    func saveMediaToPhotos(
        _ item: ReadingListItem, isDownloaderSurface: Bool, status: MediaDownloadStatusView
    ) {
        if isDownloaderSurface {
            saveLocalDownloaderMediaToPhotos(item, status: status)
            return
        }
        status.startProgress()
        Task {
            let started = await LiveMediaDownloadManager.shared.start(
                urlString: item.urlString, title: item.title)
            await MainActor.run {
                if started {
                    status.update(progress: 0.05)
                    status.showResult(message: "Download started", success: true)
                } else {
                    status.showResult(
                        message: "Couldn't start the media download.", success: false)
                }
            }
        }
    }

    private func saveLocalDownloaderMediaToPhotos(
        _ item: ReadingListItem, status: MediaDownloadStatusView
    ) {
        guard let media = SavedMediaStore.shared.item(forURLString: item.urlString) else {
            status.showResult(message: "Media is still downloading.", success: false)
            return
        }
        status.startProgress()
        Task { [photoSaver] in
            do {
                guard let fileURL = media.fileURL, let kind = media.kind else {
                    await MainActor.run {
                        status.showResult(
                            message: "Media is no longer available locally.", success: false)
                    }
                    return
                }
                guard await photoSaver.requestReadAuthorization() else {
                    await MainActor.run {
                        status.showResult(
                            message: MediaDownloadError.permissionDenied.message,
                            success: false)
                    }
                    return
                }
                let tempURL = MediaDownloadStorage.newFileURL(extension: fileURL.pathExtension)
                try FileManager.default.copyItem(at: fileURL, to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                let identifier = try await photoSaver.save(fileURL: tempURL, kind: kind)
                _ = try SavedMediaStore.shared.transitionToPhotosReference(
                    media.id, localIdentifier: identifier, kind: kind)
                await MainActor.run {
                    status.showResult(message: "Saved to Photos", success: true)
                }
            } catch {
                await MainActor.run {
                    status.showResult(
                        message: "Couldn't save to your photo library.",
                        success: false)
                }
            }
        }
    }
}
