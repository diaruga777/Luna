//
//  PluginExportInputProducer.swift
//  LunaPluginExport
//

import Foundation
import LunaEpub
import LunaModels
import LunaPluginKit
import LunaSend
import LunaStorage

/// Where a media save's downloaded file is.
///
/// LunaPluginExport sits beside the media module rather than above it, so
/// central Luna's `KindWiring` — the one place that sees both — hands the
/// answer over. Without it a `file` export of a media save refuses.
public protocol PluginExportMediaFileLocating: AnyObject {
    func mediaFileURL(forSaveID saveID: UUID) -> URL?
}

/// Why an export input could not be built.
public enum PluginExportInputError: Error, Equatable {
    /// The save is gone.
    case noSave
    /// The save has no readable article content, or no downloaded file.
    case noContent
    /// `Luna` cannot build that format for that kind. The manifest parser
    /// refuses such a declaration, so this is a wiring fault.
    case formatUnavailable(kind: PluginModelKind, format: PluginExportInputFormat)
    /// The scratch store is missing, so no file handle can be made.
    case noScratchStore
    /// Writing the input file failed.
    case writeFailed(String)
}

/// Builds the `ExportInput` for one save in one declared format (§9.1).
///
/// Heavy work — image preparation, a PDF layout, an EPUB zip — happens here,
/// off the main thread, before the hook is called. The article formats go
/// through `ArticleExportService`, so a plugin gets the same bytes the share
/// sheet's own export does.
public struct PluginExportInputProducer {

    private let store: SavesStore
    private let images: ArticleExportService
    private let mediaFiles: (any PluginExportMediaFileLocating)?

    public init(
        store: SavesStore = .shared, mediaFiles: (any PluginExportMediaFileLocating)? = nil
    ) {
        self.store = store
        images = ArticleExportService(store: store)
        self.mediaFiles = mediaFiles
    }

    /// The kind an export hook is told a save is. The derivation is the save's
    /// own (`SavedItem.exportKind`), so the send coordinator matching a save
    /// against a destination's declared kinds and the hook argument built here
    /// can never disagree.
    public static func kind(of item: SavedItem) -> PluginModelKind { item.exportKind }

    /// Builds the input, writing any file into the plugin's open scratch
    /// generation.
    ///
    /// `options` carries the declaration's `inputOptions`: a `compact` EPUB
    /// profile uses the shared compact encoder, and `images: false` skips the image
    /// preparation an EPUB would otherwise wait for.
    public func makeInput(
        saveID: UUID, format: PluginExportInputFormat, options: PluginExportSummary,
        auto: Bool, queuedRemaining: Int? = nil,
        scratch: PluginScratchStore?, pluginID: String, generation: String
    ) async throws -> PluginExportInput {
        guard let item = store.item(withID: saveID) else { throw PluginExportInputError.noSave }
        let kind = Self.kind(of: item)
        guard PluginExportInputAvailability.isAvailable(kind: kind, format: format) else {
            throw PluginExportInputError.formatUnavailable(kind: kind, format: format)
        }
        let title = item.title ?? item.urlString
        var file: PluginExportFileHandle?
        var text: String?
        var json: PluginExportJSON?

        switch format {
        case .url:
            break
        case .epub, .pdf, .docx:
            file = try await articleFile(
                item: item, format: format, options: options,
                scratch: scratch, pluginID: pluginID, generation: generation)
        case .markdown:
            text = try articleText(.markdown, item: item)
        case .text:
            text = try articleText(.plainText, item: item)
        case .html:
            guard let html = store.readerSourceHTML(for: item.id) else {
                throw PluginExportInputError.noContent
            }
            text = html
        case .json:
            json = try jsonPayload(kind: kind, item: item)
        case .file:
            file = try mediaFile(
                item: item, scratch: scratch, pluginID: pluginID, generation: generation)
        }

        return PluginExportInput(
            kind: kind, saveID: item.id, url: item.urlString, title: title, format: format,
            file: file, text: text, json: json, auto: auto,
            source: item.effectiveCaptureSource.rawValue, queuedRemaining: queuedRemaining)
    }

    /// Checked after payload preparation, immediately before invoking a destination.
    func isRead(saveID: UUID) -> Bool {
        store.item(withID: saveID)?.readState == .read
    }

    // MARK: - Article

    /// The three article formats that are a FILE. Images are fetched first —
    /// content is persisted before its pictures are, so a save exported
    /// seconds after it landed would otherwise carry none.
    private func articleFile(
        item: SavedItem, format: PluginExportInputFormat, options: PluginExportSummary,
        scratch: PluginScratchStore?, pluginID: String, generation: String
    ) async throws -> PluginExportFileHandle {
        guard let scratch else { throw PluginExportInputError.noScratchStore }
        let profile = Self.effectiveEpubProfile(options)
        let wantsImages = format != .epub || profile.includesImages
        if wantsImages { await images.prepareImages(for: item, profile: format == .epub ? profile : .standard) }
        let fresh = store.item(withID: item.id) ?? item
        guard let content = store.content(for: fresh) else {
            throw PluginExportInputError.noContent
        }
        let title = fresh.title ?? fresh.urlString
        let data: Data
        switch format {
        case .epub:
            data = EpubBuilder().build(
                content: content, sourceURLString: fresh.urlString,
                imagesDirectory: store.articlesDirectory, profile: profile)
        case .pdf:
            data = ArticlePDFBuilder().build(
                content: content, sourceURLString: fresh.urlString,
                imagesDirectory: store.articlesDirectory)
        default:
            data = ArticleDOCXBuilder().build(
                content: content, sourceURLString: fresh.urlString,
                imagesDirectory: store.articlesDirectory)
        }
        return try write(
            data, name: ArticleSendCoordinator.fileName(
                forTitle: title, extension: Self.fileExtension(format)),
            mime: Self.mimeType(format), scratch: scratch, pluginID: pluginID,
            generation: generation)
    }

    private func articleText(
        _ format: ArticleExportFormat, item: SavedItem
    ) throws -> String {
        guard let content = store.content(for: item) else {
            throw PluginExportInputError.noContent
        }
        switch format {
        case .markdown:
            return ArticleMarkdownBuilder().build(
                content: content, sourceURLString: item.urlString)
        default:
            return ArticlePlainTextBuilder().build(
                content: content, sourceURLString: item.urlString)
        }
    }

    // MARK: - JSON

    private func jsonPayload(
        kind: PluginModelKind, item: SavedItem
    ) throws -> PluginExportJSON {
        switch kind {
        case .article:
            guard let content = store.content(for: item),
                  let json = PluginExportJSON.encoding(content)
            else { throw PluginExportInputError.noContent }
            return json
        case .product:
            guard let tracker = item.priceTracker,
                  let json = PluginExportJSON.encoding(tracker)
            else { throw PluginExportInputError.noContent }
            return json
        case .media:
            guard let media = store.mediaItem(saveID: item.id),
                  let mediaJSON = PluginExportJSON.encoding(media)
            else { throw PluginExportInputError.noContent }
            return .object(["media": mediaJSON, "assets": assetsJSON(for: item)])
        }
    }

    /// What resolution found for this save, read off its download jobs — the
    /// only record of the CDN assets behind a media row.
    private func assetsJSON(for item: SavedItem) -> PluginExportJSON {
        let jobs = store.mediaDownloadJobs(forSourceURLString: item.urlString)
        var assets: [PluginExportJSON] = []
        for job in jobs {
            guard let url = job.assetURLString else { continue }
            var asset: [String: PluginExportJSON] = ["url": .string(url)]
            if let kind = job.mediaKind { asset["type"] = .string(kind.rawValue) }
            if let quality = job.quality { asset["quality"] = .string(quality) }
            if let audio = job.audioURLString { asset["audioUrl"] = .string(audio) }
            if let bytes = job.expectedByteCount { asset["bytes"] = .number(Double(bytes)) }
            assets.append(.object(asset))
        }
        return .array(assets)
    }

    // MARK: - Media file

    private func mediaFile(
        item: SavedItem, scratch: PluginScratchStore?, pluginID: String, generation: String
    ) throws -> PluginExportFileHandle {
        guard let scratch else { throw PluginExportInputError.noScratchStore }
        let locator = mediaFiles ?? PluginExportMediaFiles.locator
        guard let url = locator?.mediaFileURL(forSaveID: item.id),
              FileManager.default.fileExists(atPath: url.path)
        else { throw PluginExportInputError.noContent }
        do {
            let descriptor = try scratch.adoptFile(
                at: url, mime: nil, pluginID: pluginID, generation: generation)
            return PluginExportFileHandle(descriptor)
        } catch {
            throw PluginExportInputError.writeFailed("\(error)")
        }
    }

    // MARK: - Helpers

    private func write(
        _ data: Data, name: String, mime: String?, scratch: PluginScratchStore,
        pluginID: String, generation: String
    ) throws -> PluginExportFileHandle {
        do {
            let descriptor = try scratch.writeFile(
                data, suggestedName: name, mime: mime, pluginID: pluginID,
                generation: generation)
            return PluginExportFileHandle(descriptor)
        } catch {
            throw PluginExportInputError.writeFailed("\(error)")
        }
    }

    /// The declaration's generic EPUB profile; no destination identity is consulted.
    public static func epubProfile(_ options: PluginExportSummary) -> EpubBuilder.Profile {
        options.epubProfile == "compact" ? .compact : .standard
    }

    /// The profile the book is actually built with. `images: false` means the
    /// plugin wants no pictures, and the text-only profile is what produces a
    /// book with none — asking for images while embedding whatever happened to
    /// be on disk would answer neither request.
    static func effectiveEpubProfile(_ options: PluginExportSummary) -> EpubBuilder.Profile {
        options.epubImages ? epubProfile(options) : .textOnly
    }

    static func fileExtension(_ format: PluginExportInputFormat) -> String {
        switch format {
        case .epub: return "epub"
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .markdown: return "md"
        case .text: return "txt"
        case .html: return "html"
        case .json: return "json"
        case .url, .file: return "dat"
        }
    }

    static func mimeType(_ format: PluginExportInputFormat) -> String? {
        switch format {
        case .epub: return "application/epub+zip"
        case .pdf: return "application/pdf"
        case .docx:
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .markdown: return "text/markdown"
        case .text: return "text/plain"
        case .html: return "text/html"
        case .json: return "application/json"
        case .url, .file: return nil
        }
    }
}
