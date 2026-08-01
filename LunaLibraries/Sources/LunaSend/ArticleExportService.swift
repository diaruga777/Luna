//
//  ArticleExportService.swift
//  Luna
//

import LunaEpub
import LunaStorage
import LunaModels
import UIKit
import UniformTypeIdentifiers

/// Builds a shareable file for a saved article in any `ArticleExportFormat`, for
/// the generic "Export as…" paths. No credentials or backend — the file is
/// handed to whatever destination the user picks in the system share sheet.
///
/// Note on the Photos-style in-sheet "Options" format selector (JPEG/HEIF): that
/// is a private system affordance for `PHAsset` and is NOT available to
/// third-party apps, which is why Luna picks the format BEFORE the share sheet
/// opens (one item provider, one format). The supported in-sheet equivalent is
/// registering several representations on one `NSItemProvider` so the receiving
/// app auto-selects — but that hands the choice to the destination app instead
/// of the user, which is the opposite of what's wanted here.
public struct ArticleExportService {

    public enum ExportError: Error, Equatable {
        /// The item has no readable article content (e.g. a video).
        case noContent
    }

    private let store: ReadingListStore

    public init(store: ReadingListStore = .shared) {
        self.store = store
    }

    /// Builds `format` and writes it to a temp file, returning its URL. Throws
    /// `ExportError.noContent` when the item has no extracted content — the one
    /// gate that keeps still-locked and media items out of every format.
    /// Heavy (zips images, or lays out every PDF page) — call off the main thread.
    public func write(_ format: ArticleExportFormat, for item: ReadingListItem) throws -> URL {
        guard let content = store.content(for: item) else { throw ExportError.noContent }
        let data = try self.data(format, content: content, sourceURLString: item.urlString)
        let fileName = ArticleSendCoordinator.fileName(
            forTitle: item.title ?? item.urlString, extension: format.fileExtension)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Serialized bytes for one format. The two text formats are UTF-8; a string
    /// that somehow can't encode as UTF-8 is reported as no content rather than
    /// written out as an empty file.
    private func data(
        _ format: ArticleExportFormat, content: ArticleContent, sourceURLString: String
    ) throws -> Data {
        switch format {
        case .epub:
            return EpubBuilder().build(
                content: content,
                sourceURLString: sourceURLString,
                imagesDirectory: store.articlesDirectory)
        case .pdf:
            return ArticlePDFBuilder().build(
                content: content,
                sourceURLString: sourceURLString,
                imagesDirectory: store.articlesDirectory)
        case .richText:
            return ArticleRTFBuilder().build(
                content: content,
                sourceURLString: sourceURLString,
                imagesDirectory: store.articlesDirectory)
        case .markdown:
            let text = ArticleMarkdownBuilder().build(
                content: content, sourceURLString: sourceURLString)
            guard let data = text.data(using: .utf8) else { throw ExportError.noContent }
            return data
        case .plainText:
            let text = ArticlePlainTextBuilder().build(
                content: content, sourceURLString: sourceURLString)
            guard let data = text.data(using: .utf8) else { throw ExportError.noContent }
            return data
        }
    }

    /// Builds the EPUB and writes it to a temp file, returning its URL — the
    /// pre-multi-format spelling of `write(.epub, for:)`.
    public func writeEPUB(for item: ReadingListItem) throws -> URL {
        try write(.epub, for: item)
    }

    /// An item provider advertising the article as a file in `format`, for the
    /// share sheet. Built from the temp file so its UTType (e.g.
    /// `org.idpf.epub-container`, `com.adobe.pdf`) is inferred from the extension.
    public func itemProvider(
        _ format: ArticleExportFormat = .epub, for item: ReadingListItem
    ) throws -> NSItemProvider {
        let fileURL = try write(format, for: item)
        guard let provider = NSItemProvider(contentsOf: fileURL) else {
            throw ExportError.noContent
        }
        return provider
    }

    /// Builds the file off the main thread and presents the system share sheet
    /// anchored to `sourceView`, or an alert if the article has no content.
    /// Call on the main thread; it hops to a background queue to build, then back.
    public func presentShareSheet(
        _ format: ArticleExportFormat = .epub, for item: ReadingListItem,
        from presenter: UIViewController, sourceView: UIView
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileURL = try? self.write(format, for: item)
            DispatchQueue.main.async { [weak presenter] in
                guard let presenter else { return }
                guard let fileURL else {
                    let alert = UIAlertController(
                        title: L10n.string("Couldn't Export Article"),
                        message: L10n.string("This article has no readable content to export."),
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: L10n.string("OK"), style: .default))
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
