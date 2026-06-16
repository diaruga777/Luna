//
//  ArticleExportService.swift
//  Clip
//

import UIKit
import UniformTypeIdentifiers

/// Builds a shareable EPUB file for a saved article, for the generic "Share
/// eBook…" path (Apple Books, Kobo, reMarkable, Boox, Files, AirDrop, …). No
/// credentials or backend — the EPUB is handed to whatever destination the user
/// picks in the system share sheet.
///
/// Note on the Photos-style in-sheet "Options" format selector (JPEG/HEIF): that
/// is a private system affordance for `PHAsset` and is NOT available to
/// third-party apps. The supported equivalent is registering multiple
/// representations on one `NSItemProvider` so the receiving app auto-selects the
/// format it supports — see `itemProvider(for:)`. Today only EPUB is produced;
/// a future PDF representation would register alongside it.
struct ArticleExportService {

    enum ExportError: Error, Equatable {
        /// The item has no readable article content (e.g. a video).
        case noContent
    }

    private let store: ReadingListStore

    init(store: ReadingListStore = .shared) {
        self.store = store
    }

    /// Builds the EPUB and writes it to a temp file, returning its URL. Throws
    /// `ExportError.noContent` when the item has no extracted content. Heavy
    /// (zips content + images) — call off the main thread.
    func writeEPUB(for item: ReadingListItem) throws -> URL {
        guard let content = store.content(for: item) else { throw ExportError.noContent }
        let data = EpubBuilder().build(
            content: content,
            sourceURLString: item.urlString,
            imagesDirectory: store.articlesDirectory)
        let fileName = ArticleSendCoordinator.epubFileName(forTitle: item.title ?? item.urlString)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// An item provider advertising the article as an EPUB file, for the share
    /// sheet. Built from the temp file so its UTType (`org.idpf.epub-container`)
    /// is inferred from the `.epub` extension.
    func itemProvider(for item: ReadingListItem) throws -> NSItemProvider {
        let fileURL = try writeEPUB(for: item)
        guard let provider = NSItemProvider(contentsOf: fileURL) else {
            throw ExportError.noContent
        }
        return provider
    }

    /// Builds the EPUB off the main thread and presents the system share sheet
    /// anchored to `sourceView`, or an alert if the article has no content.
    @MainActor
    func presentShareSheet(
        for item: ReadingListItem, from presenter: UIViewController, sourceView: UIView
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileURL = try? self.writeEPUB(for: item)
            DispatchQueue.main.async { [weak presenter] in
                guard let presenter else { return }
                guard let fileURL else {
                    let alert = UIAlertController(
                        title: "Couldn't Create eBook",
                        message: "This article has no readable content to export.",
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    presenter.present(alert, animated: true)
                    return
                }
                let activity = UIActivityViewController(
                    activityItems: [fileURL], applicationActivities: nil)
                activity.popoverPresentationController?.sourceView = sourceView
                presenter.present(activity, animated: true)
            }
        }
    }
}
