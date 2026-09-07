//
//  ArticleModelAdopter.swift
//  LunaReaderUI
//

import Foundation
import LunaDocuments
import LunaHTMLClassification
import LunaModels
import LunaURLClassification

/// Turns a plugin's `article` Model into reader content
/// (`claudedocs/plans/plugin-platform.md` §5.2).
///
/// The Model's `html` is the body the plugin already chose, so this converts it
/// as trusted — `ArticleExtractor.convertTrusted`, no readability scoring and no
/// boilerplate removal. Images and the cover thumbnail are not fetched here: the
/// stage answers `Outcome.article`, and `ArticleIngestHandler.persistArticle`
/// runs the existing downloader over it like any other article.
///
/// It lives in LunaReaderUI rather than LunaArticleIngest because a `document`
/// Model needs `DocumentParser`, and LunaArticleIngest does not link
/// LunaDocuments.
public struct ArticleModelAdopter: ArticleModelAdopting {

    private let extractor: ArticleExtractor
    private let session: URLSession

    public init(extractor: ArticleExtractor = ArticleExtractor(), session: URLSession = .shared) {
        self.extractor = extractor
        self.session = session
    }

    public func adopt(
        _ model: ArticleModel, url: URL, page: CapturedPage, pluginID: String
    ) async -> PluginAdoptedOutcome {
        let base = model.baseURL ?? url

        // A document the plugin pointed at IS the article. It is read through
        // the same parser a shared file goes through, and the Model's HTML
        // stands in when the fetch or the parse fails.
        if let spec = model.document,
           let content = await documentContent(spec, title: model.title, author: model.author) {
            return .article(content, sourceHTML: model.html)
        }

        // A recording the plugin pointed at IS the article, once the app has
        // transcribed it. Nothing is fetched here: the request parks the save,
        // and the runner does the work (`claudedocs/plans/transcription-plugins.md`
        // §3.6).
        if let spec = model.transcription {
            return .transcription(
                transcriptionRequest(spec, model: model, base: base, pluginID: pluginID))
        }

        guard var content = try? extractor.convertTrusted(
            fragmentHTML: model.html, baseURL: base,
            title: model.title, author: model.author)
        else { return .failed(.notReadable) }

        if let lead = model.leadImageURL, !content.blocks.contains(where: { $0.kind == .image }) {
            content.blocks.insert(
                ArticleContent.Block(
                    kind: .image, text: "", links: [], imageURLString: lead.absoluteString),
                at: 0)
        }
        return .article(content, sourceHTML: model.html)
    }

    // MARK: - The optional recording

    /// The Model's html, when it has any, becomes the lead the transcript
    /// follows: a video's description or the post's own text.
    private func transcriptionRequest(
        _ spec: ArticleTranscriptionSpec, model: ArticleModel, base: URL, pluginID: String
    ) -> TranscriptionRequest {
        var lead: ArticleContent?
        if !model.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           var content = try? extractor.convertTrusted(
               fragmentHTML: model.html, baseURL: base,
               title: model.title, author: model.author),
           !content.blocks.isEmpty {
            if let leadImage = model.leadImageURL,
               !content.blocks.contains(where: { $0.kind == .image }) {
                content.blocks.insert(
                    ArticleContent.Block(
                        kind: .image, text: "", links: [],
                        imageURLString: leadImage.absoluteString),
                    at: 0)
            }
            lead = content
        }
        let kind: TranscriptionRequest.MediaKind
        switch spec.type {
        case .audio: kind = .audio
        case .video: kind = .video
        }
        return TranscriptionRequest(
            mediaURL: spec.url, mediaKind: kind, audioURL: spec.audioURL,
            requestHeaders: spec.headers, expiresAt: spec.expiresAt,
            language: model.language, title: model.title, author: model.author,
            pluginID: pluginID, leadContent: lead)
    }

    // MARK: - The optional document

    /// The ceiling on the document a plugin points at, the same one
    /// `PluginFetchService` holds every `luna.fetch` to. This fetch is the
    /// adopter's own, so without it a `document.url` naming a multi-gigabyte
    /// file would fill the container.
    static let maxDocumentBytes = WebFetchConstants.maxBytes

    /// The response body, or nil on a transport failure, a non-2xx status, or a
    /// body over the ceiling. The transfer is read as a stream and abandoned the
    /// moment it passes the ceiling, so an over-sized body is never held whole.
    private func body(for request: URLRequest) async -> Data? {
        guard let (stream, response) = try? await session.bytes(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        let declared = response.expectedContentLength
        guard declared <= Int64(Self.maxDocumentBytes) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(declared > 0 ? Int(declared) : 64 * 1024)
        do {
            for try await byte in stream {
                bytes.append(byte)
                if bytes.count > Self.maxDocumentBytes { return nil }
            }
        } catch {
            return nil
        }
        return Data(bytes)
    }

    private func documentContent(
        _ spec: ArticleDocumentSpec, title: String, author: String?
    ) async -> ArticleContent? {
        // The decoder already refused any header name outside
        // `PluginModelCaps.allowedHeaderNames`, so the spec's set is the
        // allowed set.
        var request = URLRequest(url: spec.url)
        for (name, value) in spec.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        guard let data = await body(for: request) else { return nil }

        // `DocumentParser` reads a file, so the bytes land in a scratch file
        // named with the declared extension and are unlinked straight after.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(spec.type.rawValue)
        guard (try? data.write(to: scratch)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard var content = DocumentParser.parse(
            fileURL: scratch, type: spec.type.rawValue, title: title)
        else { return nil }
        content.title = title
        if let author { content.author = author }
        return content
    }
}
