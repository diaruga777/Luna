//
//  ArticleModelAdopter.swift
//  LunaReaderUI
//

import Foundation
import LunaDocuments
import LunaHTMLClassification
import LunaModels

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

    /// Only these travel with a plugin's document fetch
    /// (`PluginModelCaps.allowedHeaderNames`), so a Model cannot smuggle a
    /// header the fetch layer would honour.
    static let allowedHeaderNames = PluginModelCaps.allowedHeaderNames

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

    // MARK: - The optional document

    private func documentContent(
        _ spec: ArticleDocumentSpec, title: String, author: String?
    ) async -> ArticleContent? {
        var request = URLRequest(url: spec.url)
        for (name, value) in spec.headers
        where Self.allowedHeaderNames.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }

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
