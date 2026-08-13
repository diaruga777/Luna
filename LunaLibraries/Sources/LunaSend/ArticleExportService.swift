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

    /// Builds `format` and writes it to a temporary file/package, returning its URL. Throws
    /// `ExportError.noContent` when the item has no extracted content — the one
    /// gate that keeps still-locked and media items out of every format.
    /// Heavy (zips images, or lays out every PDF page) — call off the main thread.
    public func write(_ format: ArticleExportFormat, for item: ReadingListItem) throws -> URL {
        guard let content = store.content(for: item) else { throw ExportError.noContent }
        logImageResolution(for: content, format: format)
        let fileName = ArticleSendCoordinator.fileName(
            forTitle: item.title ?? item.urlString, extension: format.fileExtension)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
        let data = try self.data(
            format, content: content, sourceURLString: item.urlString)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Records what the export could actually see, so "my PDF has no pictures"
    /// is answerable from the Diagnostics screen instead of by guesswork: how
    /// many image blocks the content has, how many resolved to a file on disk,
    /// and — when they differ — how the ones that didn't were named.
    private func logImageResolution(for content: ArticleContent, format: ArticleExportFormat) {
        let imageBlocks = content.blocks.filter { $0.kind == .image }
        guard !imageBlocks.isEmpty else { return }
        let directory = store.articlesDirectory
        let resolved = imageBlocks.filter {
            ArticleImageFiles.localFileName(for: $0, in: directory) != nil
        }
        var message = "export \(format.rawValue): \(resolved.count)/\(imageBlocks.count) images resolved"
        if resolved.count < imageBlocks.count {
            let unresolved = imageBlocks
                .filter { ArticleImageFiles.localFileName(for: $0, in: directory) == nil }
                .prefix(3)
                .map { "recorded=\($0.imageFileName ?? "nil") url=\($0.imageURLString ?? "nil")" }
            message += " — missing: \(unresolved.joined(separator: "; "))"
        }
        SharedDiagnosticLog.record(message, category: "export")
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
        case .document:
            return ArticleDOCXBuilder().build(
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

    /// `write`, but first downloading any of the article's images that aren't
    /// on disk yet (`ArticleExportImages`, bounded by its own timeout).
    ///
    /// **This is the form every user-facing export should call.** Content is
    /// persisted before its pictures are, so `write` alone exports whatever a
    /// reader happened to have fetched — which, for a save that was never
    /// opened or an export taken seconds after the save, is nothing.
    @discardableResult
    func writePreparingImages(
        _ format: ArticleExportFormat, for item: ReadingListItem
    ) async throws -> URL {
        await prepareImages(for: item)
        return try write(format, for: item)
    }

    /// The second intent can arrive after the first has committed its placeholder
    /// but before extraction has committed article content. Keep the double-save
    /// action alive for that in-flight save instead of silently returning no
    /// document. Ordinary exports use `writePreparingImages` and fail promptly.
    public func writePreparingImagesWhenAvailable(
        _ format: ArticleExportFormat, for item: ReadingListItem,
        timeout: TimeInterval = 12
    ) async throws -> URL {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            guard let current = store.item(withID: item.id) else {
                throw ExportError.noContent
            }
            if store.content(for: current) != nil {
                return try await writePreparingImages(format, for: current)
            }
            guard Date() < deadline else { throw ExportError.noContent }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Fetches the article's missing images and persists the enriched content,
    /// so the work is done once: the next export, reader open, or Kindle send
    /// finds the files already recorded. Persisting through `saveContent` is also
    /// what makes the save OWN the new files, which is what keeps them from being
    /// collected as orphans.
    public func prepareImages(for item: ReadingListItem) async {
        guard let content = store.content(for: item),
              let prepared = await ArticleExportImages.prepared(
                content, for: item, imagesDirectory: store.articlesDirectory)
        else { return }
        _ = store.saveContent(prepared, for: item)
    }

    /// Fetches any missing images, builds the file off the main thread, and
    /// presents the system share sheet anchored to `sourceView` — or an alert if
    /// the article has no content. Call on the main thread.
    ///
    /// The sheet waits on the image preparation. That's deliberate: an export
    /// with the pictures missing is the wrong file, and the wait is nil whenever
    /// they're already local (the common case).
    public func presentShareSheet(
        _ format: ArticleExportFormat = .epub, for item: ReadingListItem,
        from presenter: UIViewController, sourceView: UIView
    ) {
        Task { @MainActor in
            await self.prepareImages(for: item)
            self.buildAndPresent(
                format, for: item, from: presenter, sourceView: sourceView)
        }
    }

    private func buildAndPresent(
        _ format: ArticleExportFormat, for item: ReadingListItem,
        from presenter: UIViewController, sourceView: UIView
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak presenter] in
            let fileURL = try? self.write(format, for: item)
            DispatchQueue.main.async {
                guard let presenter else { return }
                guard let fileURL else {
                    let alert = UIAlertController(
                        title: L10n.string("Reader_export_failureTitle"),
                        message: L10n.string("Reader_export_failureMessage"),
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
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
