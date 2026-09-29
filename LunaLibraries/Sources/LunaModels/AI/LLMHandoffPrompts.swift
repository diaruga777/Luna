//
//  LLMHandoffPrompts.swift
//  LunaModels
//

import Foundation

/// The prompts Luna hands to an external chat model (ChatGPT, Claude) through
/// a deep link. Pure text assembly: no I/O, no provider knowledge. Every
/// prompt stays under `maxCharacters` because it travels in a URL query
/// (`claudedocs/plans/ai-flows.md` §2, §7); `LLMHandoffPromptTests` pins the
/// budget for the longest realistic inputs.
///
/// Two contracts appear in every prompt and must agree with the parsers:
/// the Luna file header (`LunaFileHeader`, marker `luna-recovery` or
/// `luna-plugin`) and the content Model shapes (`PluginModel`'s decoder).
public enum LLMHandoffPrompts {

    /// The ceiling any prompt must stay under before URL encoding.
    public static let maxCharacters = 3_600

    /// Where the hosted plugin API reference lives (`docs/plugins/llm-api.md`,
    /// published as `site/dist/p1`). Short on purpose: it is inside the URL.
    public static let pluginAPIReferenceURL = "https://luna-site-bm6.pages.dev/p1"

    /// User-supplied text is bounded before it enters a prompt.
    public static let maxDescriptionCharacters = 1_200
    public static let maxFailureCharacters = 220
    /// The correction prompt carries the request AND the findings, so each
    /// gets less room than the creation prompt gives the request alone.
    public static let maxCorrectionDescriptionCharacters = 900
    public static let maxErrorsCharacters = 700

    // MARK: - Recovery

    /// The failed-save hand-off. `failure` is the recorded failure sentence
    /// (`SaveFailureReason` rendered for a reader), `app` decides which content
    /// kind the model is asked for and the file extension it must use.
    public static func recovery(url: URL, app: LunaApp, failure: String?) -> String {
        let ext = app.fileExtension ?? "luna"
        let link = url.absoluteString
        var parts: [String] = []
        parts.append("""
        Luna, a save-it-for-later app on my iPhone, could not save this page:
        \(link)
        """)
        if let failure = bounded(failure, limit: maxFailureCharacters), !failure.isEmpty {
            parts.append("What went wrong: \(failure).")
        }
        parts.append("""
        Recover it for me. Open the URL yourself. If it is blocked, try its print, AMP or mobile variant, its canonical URL, a Web Archive copy (web.archive.org), or search for its title. Never invent content: if you truly cannot read the page, say so instead of guessing.

        Reply with ONE file named "<title>.\(ext)" and nothing else. Attach it as a downloadable file; if you cannot attach files, put the whole file in a single code block. The file is:

        /* luna-recovery
        {"api":1,"url":"\(link)","kind":"<kind>"}
        */
        {"content":<content>,"recipe":<recipe>}

        \(kindGuidance(for: app))

        "recipe" is optional. Include it when a different route got you the page, so Luna can fetch it that way itself: {"url":"https://…","headers":{"user-agent":"googlebot","referer":"…"},"javascript":"…"}. The url must be on the same site, or on web.archive.org or r.jina.ai. Allowed headers: user-agent (iphone_safari, desktop_safari, googlebot, facebook_crawler, or a literal string), referer, accept-language. javascript is optional, under 8 KB, runs on that page in a browser and must return the content HTML as a string. Omit the key entirely when there is no recipe.

        Rules: valid UTF-8 JSON after the header, no comments, no Markdown, no explanation outside the file. Copy text verbatim; never summarize or paraphrase.
        """)
        return parts.joined(separator: "\n")
    }

    private static func kindGuidance(for app: LunaApp) -> String {
        let article = """
        article: {"kind":"article","title":"…","author":"…","publishedAt":"YYYY-MM-DD","language":"en","leadImageURL":"https://…","html":"<p>…</p>"}. html is the COMPLETE body as clean HTML (p, h2, h3, blockquote, ul, ol, li, img with absolute src, a with absolute href), verbatim, with no navigation, ads, related links or comments.
        """
        let product = """
        product: {"kind":"product","name":"…","price":{"amount":"129.99","currency":"USD"},"imageURL":"https://…","brand":"…"}. Copy the current price exactly as shown: amount is digits with a dot, currency is ISO 4217.
        """
        let media = """
        media: {"kind":"media","title":"…","assets":[{"url":"https://…/file.mp4","type":"video"}]}. Direct file URLs only; type is video, image, gif or audio.
        """
        switch app {
        case .reader:
            return "\"kind\" is \"article\" (Luna Reader saves articles). \"content\" is:\n" + article
        case .priceTracker:
            return "\"kind\" is \"product\" (Luna Price Tracker tracks products). \"content\" is:\n" + product
        case .downloader:
            return "\"kind\" is \"media\" (Luna Video saves videos, images and audio). \"content\" is:\n" + media
        case .luna, .vault, .writer:
            return """
            Decide "kind" from the page: article for a readable piece, product for one item with a current price, media for a page whose point is a video, image or audio file. Use the same value in the header and in "content". "content" is one of:
            \(article)\(product)\(media)
            """
        }
    }

    // MARK: - Plugin creation

    /// The Settings / failed-card plugin request. `description` is the user's
    /// own words (plus, from a failed card, the URL and what failed); `host`
    /// is the site to name in the manifest skeleton when known.
    public static func pluginCreation(description: String, host: String?) -> String {
        """
        Write a plugin for Luna, an iOS save-it-for-later app. A Luna plugin is ONE JavaScript file that extracts articles, products or media from URLs, or exports saved items. Read the API reference first: \(pluginAPIReferenceURL)

        What I want:
        --- REQUEST ---
        \(bounded(description, limit: maxDescriptionCharacters) ?? "")
        --- END REQUEST ---

        \(pluginContract(host: host))
        """
    }

    /// The "Generate again" prompt: a fresh chat gets the original request plus
    /// the validator's findings, and is asked for a complete new file.
    public static func pluginCorrection(description: String, host: String?, errors: [String]) -> String {
        let list = errors.map { "- " + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
        return """
        A Luna plugin generated for the request below failed Luna's checks. Write a corrected plugin from scratch that avoids every listed problem. Luna is an iOS save-it-for-later app; a plugin is ONE JavaScript file for URL extraction or exporting saved items. Read the API reference first: \(pluginAPIReferenceURL)

        --- REQUEST ---
        \(bounded(description, limit: maxCorrectionDescriptionCharacters) ?? "")
        --- END REQUEST ---
        --- PROBLEMS FOUND ---
        \(bounded(list, limit: maxErrorsCharacters) ?? "")
        --- END PROBLEMS ---

        \(pluginContract(host: host, compact: true))
        """
    }

    /// The delivery contract every plugin prompt ends with. `compact` drops the
    /// requirements bullets (the reference page carries them) so a correction
    /// prompt has room for the findings.
    private static func pluginContract(host: String?, compact: Bool = false) -> String {
        let raw = host?.lowercased() ?? "example.com"
        let site = raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
        let requirements = compact ? "" : """

        Requirements:
        - ES2022, no import/export/require or libraries. Use luna.parseURL and luna.bytes; URL, fetch and TextEncoder globals are unavailable. No polling or busy loops.
        - Never invent content, prices or URLs. Prefer luna.fetch.json/doc, luna.html.meta/jsonLD/article and luna.text.price/date. Await article(). Keep final URLs after redirects. Let browser-deferred propagate through catch handlers.
        - For exports, omit produces/match and replace the ingest hooks with export(input). Declare export:{kinds:["article"],input:"markdown",title:"Export"}; read input.text. Return {text}, {url}, {file}, a delivery status, or null. See the reference for settings/device APIs.

        """
        return """
        Deliver ONE file named "<name>.luna" as a downloadable attachment (or one complete code block). No text outside the file.
        Start with the JSON header; register once. Use a stable [a-z0-9.-] id, name ≤40 characters and only needed capabilities.
        Host-specific plugins precede match.any, then higher priority runs first. Bundled extractors use 100; use 101 to override one for the same host, or 0 for a new site. A valid result stops the walk.

        Article starter (adapt hosts and paths):
        /* luna-plugin
        {"id":"user.\(site)","name":"Example","version":"1.0.0","api":1,"produces":["article"],"match":{"hosts":["\(site)","*.\(site)"]},"capabilities":["fetch","html"]}
        */
        luna.register({
          classify({url}) { return /\\/articles\\/[^/]+/.test(luna.parseURL(url)?.pathname || "") ? {kind:"article"} : false; },
          async ingest({url, page}) {
            const source = page?.html ? {text:page.html,url:page.url} : await luna.fetch(url);
            if (source.ok === false) return null;
            const article = await luna.html.article(source.text, source.url);
            return article ? {kind:"article", ...article, baseURL:source.url} : null;
          }
        });
        \(requirements)
        Check the header, capabilities, required hooks and returned Model fields. An article needs title and html, document or transcription; a product needs name and price:{amount:"12.34",currency:"USD"}; media needs assets:[{url,type:"video"|"image"|"gif"|"audio"}].
        """
    }

    // MARK: - Helpers

    static func bounded(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
