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
        Write a plugin for Luna, an iOS save-it-for-later app. A Luna plugin is ONE JavaScript file that turns a URL into something Luna saves: an article, a product with its price, or a media file. Read the API reference first: \(pluginAPIReferenceURL)

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
        A Luna plugin generated for the request below failed Luna's checks. Write a corrected plugin from scratch that avoids every listed problem. Luna is an iOS save-it-for-later app; a plugin is ONE JavaScript file that turns a URL into an article, a product with its price, or a media file. Read the API reference first: \(pluginAPIReferenceURL)

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
        - The header comment is the first thing in the file and its JSON is the manifest: id uses [a-z0-9.-]; name is 40 characters or fewer; produces lists the kinds ingest can return (article, media, product); match.hosts are exact hosts or *.wildcards; capabilities lists only the luna namespaces the code calls.
        - classify is fast: it decides from the URL shape and returns false for anything that is not this content.
        - ingest returns a Model whose kind is in produces, or null when the page has none. Article: {kind, title, html, author?, publishedAt?, language?, leadImageURL?}. Product: {kind, name, price:{amount:"12.34",currency:"USD"}, imageURL?, brand?}. Media: {kind, title?, assets:[{url, type:"video"|"image"|"gif"|"audio"}]}. Never invent text, prices or URLs.
        - Prefer the helpers over hand-written parsing: luna.fetch.doc / .text / .json, luna.html.meta, luna.html.jsonLD, luna.html.article, luna.text.price, luna.text.date. Fetch only the page's own site. Catch errors. No polling or busy loops.
        - ES2022 JavaScript, no import/export/require, no libraries, exactly one top-level luna.register.

        """
        return """
        Deliver ONE file named "<name>.luna" as a downloadable attachment (if you cannot attach files, put the whole file in a single code block). No text outside the file.

        File shape:
        /* luna-plugin
        {"id":"user.\(site)","name":"\(site)","version":"1.0.0","api":1,"produces":["article"],"match":{"hosts":["\(site)","*.\(site)"]},"capabilities":["fetch","html"]}
        */
        luna.register({
          classify({ url }) { /* decide from the URL alone */ return { kind: "article" }; },
          async ingest({ url }) { const doc = await luna.fetch.doc(url); /* … */ return model; }
        });
        \(requirements)
        Before answering, check: the header parses as JSON; every luna namespace used is declared in capabilities; ingest returns only kinds listed in produces; the Model has its required fields; classify returns false for other pages.
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
