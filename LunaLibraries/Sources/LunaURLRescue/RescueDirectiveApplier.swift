//
//  RescueDirectiveApplier.swift
//  LunaURLRescue
//

import Foundation
import LunaFetch
import LunaIngest
import LunaMediaDownload
import LunaModels

/// Executes a validated `RescueDirective`. Re-entry into the pipeline uses the
/// injected `runPipeline` closure whose default is the RAW
/// `IngestPipeline.processResolved` — never a rescuing wrapper — which is the
/// structural guarantee that a rescue can never trigger a second LLM pass.
struct RescueDirectiveApplier {
    let fetcher: HTMLFetching
    let scriptRunner: RescueScriptRunning
    let mediaResolver: SocialMediaResolving
    /// MUST be the raw pipeline; the integration layer injects
    /// `IngestPipeline.processResolved`, never its rescuing wrapper.
    let runPipeline: (IngestInput) async -> IngestResult

    func apply(_ directive: RescueDirective, request: RescueRequest) async -> RescueOutcome {
        switch directive {
        case let .articlePayload(content):
            return .rescued(
                IngestResult(url: request.url, outcome: .article(content, html: request.fetchedHTML ?? "")),
                method: .articlePayload)

        case let .productPayload(info):
            return .rescued(
                IngestResult(url: request.url, outcome: .product(info, html: request.fetchedHTML ?? "")),
                method: .productPayload)

        case let .reroute(reroute):
            return await applyReroute(reroute, request: request, method: .reroute)

        case let .webJS(script):
            return await applyWebJS(script, request: request)

        case let .mediaURL(url):
            return await applyMediaURL(url, method: .mediaURL)

        case .giveUp:
            return .unrescuable
        }
    }

    // MARK: - Reroute

    private func applyReroute(_ reroute: RescueReroute, request: RescueRequest, method: RescueMethod) async -> RescueOutcome {
        let forceArticle = request.hint == .article
        if reroute.headers.isEmpty {
            let input = IngestInput(url: reroute.url, source: request.source, forceArticle: forceArticle)
            return classify(await runPipeline(input), request: request, method: method)
        }
        // Custom headers → fetch ourselves and hand the pipeline the HTML. Use the
        // existing HTMLFetching variants when they fit, else the header fetch.
        let html = await fetchWithHeaders(url: reroute.url, headers: reroute.headers)
        guard let html else { return .unrescuable }
        let input = IngestInput(
            url: reroute.url, source: request.source, prefetchedHTML: html,
            forceArticle: forceArticle, trustsPrefetchedHTML: false)
        return classify(await runPipeline(input), request: request, method: method)
    }

    private func fetchWithHeaders(url: URL, headers: RescueHeaders) async -> String? {
        // Prefer the vetted, single-purpose fetchers where the header set matches.
        if let ua = headers.userAgent, headers.referer == nil, headers.acceptLanguage == nil {
            return try? await fetcher.fetchHTML(from: url, userAgent: ua, xForwardedFor: headers.xForwardedFor)
        }
        if let referer = headers.referer, headers.userAgent == nil, headers.acceptLanguage == nil, headers.xForwardedFor == nil {
            return try? await fetcher.fetchHTML(from: url, referer: referer.absoluteString)
        }
        return await RescueHeaderFetch.fetchHTML(url: url, headers: headers)
    }

    // MARK: - WebJS

    private func applyWebJS(_ script: RescueScript, request: RescueRequest) async -> RescueOutcome {
        guard let result = await scriptRunner.run(script) else { return .unrescuable }
        switch script.resultKind {
        case .html, .json:
            if request.hint == .media {
                let assets = await mediaAssets(fromHTML: result, pageURL: script.pageURL)
                return assets.isEmpty ? .unrescuable : .rescuedMedia(assets, method: .webJS)
            }
            let html = script.resultKind == .json ? Self.wrapJSONAsHTML(result) : result
            let forceArticle = request.hint == .article
            let input = IngestInput(
                url: script.pageURL, source: request.source, prefetchedHTML: html,
                forceArticle: forceArticle, trustsPrefetchedHTML: false)
            return classify(await runPipeline(input), request: request, method: .webJS)
        case .mediaURL:
            guard let url = URL(string: result.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return .unrescuable
            }
            return await applyMediaURL(url, method: .webJS)
        }
    }

    /// A bare JSON result is wrapped as an embedded JSON-LD script so the
    /// pipeline's existing JSON-LD / embedded-JSON scanners find it.
    static func wrapJSONAsHTML(_ json: String) -> String {
        "<html><head><script type=\"application/ld+json\">\(json)</script></head><body></body></html>"
    }

    // MARK: - Media

    private func applyMediaURL(_ url: URL, method: RescueMethod) async -> RescueOutcome {
        // A direct media file → a single asset. Kind inferred from extension.
        if let asset = Self.directAsset(from: url) {
            return .rescuedMedia([asset], method: method)
        }
        // Otherwise treat it as a page the resolver can extract assets from.
        let assets = await mediaResolver.resolveAssets(for: url)
        return assets.isEmpty ? .unrescuable : .rescuedMedia(assets, method: method)
    }

    private func mediaAssets(fromHTML html: String, pageURL: URL) async -> [MediaAsset] {
        // Try Open Graph video/image first, then fall back to the resolver on the page URL.
        for property in ["og:video:url", "og:video", "og:image"] {
            if let raw = Self.openGraphContent(named: property, in: html),
               let url = URL(string: raw), let asset = Self.directAsset(from: url) {
                return [asset]
            }
        }
        return await mediaResolver.resolveAssets(for: pageURL)
    }

    /// Minimal Open Graph `content` extractor (the module's own parser is
    /// private). Attribute order isn't stable, so inspect each `<meta>` tag.
    static func openGraphContent(named name: String, in html: String) -> String? {
        for tag in html.components(separatedBy: "<meta") {
            let lower = tag.lowercased()
            guard lower.contains("property=\"\(name)\"") || lower.contains("property='\(name)'")
                    || lower.contains("name=\"\(name)\"") || lower.contains("name='\(name)'") else { continue }
            for quote in ["\"", "'"] {
                let marker = "content=\(quote)"
                guard let start = tag.range(of: marker, options: [.caseInsensitive])?.upperBound,
                      let end = tag[start...].firstIndex(of: Character(quote)) else { continue }
                return String(tag[start..<end]).replacingOccurrences(of: "&amp;", with: "&")
            }
        }
        return nil
    }

    static func directAsset(from url: URL) -> MediaAsset? {
        let ext = url.pathExtension.lowercased()
        let kind: MediaAsset.Kind?
        switch ext {
        case "mp4", "m3u8", "mov", "webm": kind = .video
        case "gif": kind = .gif
        case "jpg", "jpeg", "png", "webp": kind = .image
        case "mp3", "m4a": kind = .audio
        default: kind = nil
        }
        guard let kind else { return nil }
        return MediaAsset(url: url, kind: kind)
    }

    // MARK: - Outcome classification

    /// Only a genuine article/product from the re-run counts as rescued. A
    /// `.failed`/`.needsArchive` second pass means the rescue didn't work (and
    /// can NOT loop — the pipeline was called at most once with the raw closure).
    private func classify(_ result: IngestResult, request: RescueRequest, method: RescueMethod) -> RescueOutcome {
        switch result.outcome {
        case .article, .product:
            return .rescued(result, method: method)
        case .social, .video, .document, .needsArchive, .failed, .unsupported:
            return .unrescuable
        }
    }
}
