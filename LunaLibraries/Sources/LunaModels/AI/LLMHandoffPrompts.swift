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

        Reply with ONE file named "<title>.\(ext)" and nothing else.
        \(binaryDeliveryInstructions)
        The source to encode is:

        /* luna-recovery
        {"api":1,"url":"\(link)","kind":"<kind>"}
        */
        {"content":<content>,"recipe":<recipe>}

        \(kindGuidance(for: app))

        "recipe" is optional. Include it when a different route got you the page, so Luna can fetch it that way itself: {"url":"https://…","headers":{"user-agent":"googlebot","referer":"…"},"javascript":"…"}. The url must be on the same site, or on web.archive.org or r.jina.ai. Allowed headers: user-agent (iphone_safari, desktop_safari, googlebot, facebook_crawler, or a literal string), referer, accept-language. javascript is optional, under 8 KB, runs on that page in a browser and must return the content HTML as a string. Omit the key entirely when there is no recipe.

        Source rules: valid UTF-8 JSON after the header, no comments or Markdown. Copy text verbatim; never summarize or paraphrase.
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
        let intro = "Write a Luna JavaScript plugin to extract articles/products/media or export saves. Read first: \(pluginAPIReferenceURL)"
        return pluginPrompt(intro: intro, description: description, limit: maxDescriptionCharacters,
                            suffix: pluginContract(host: host))
    }

    /// The "Generate again" prompt: a fresh chat gets the original request plus
    /// the validator's findings, and is asked for a complete new file.
    public static func pluginCorrection(description: String, host: String?, errors: [String]) -> String {
        let list = errors.map { "- " + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
        let intro = "This Luna JavaScript plugin failed validation. Write a corrected plugin from scratch for the request below, fixing every listed problem. Read the API reference first: \(pluginAPIReferenceURL)"
        let suffix = """
        --- PROBLEMS FOUND ---
        \(bounded(list, limit: maxErrorsCharacters) ?? "")
        --- END PROBLEMS ---

        \(pluginContract(host: host, compact: true))
        """
        return pluginPrompt(intro: intro, description: description, limit: maxCorrectionDescriptionCharacters,
                            suffix: suffix)
    }

    private static func pluginPrompt(intro: String, description: String, limit: Int, suffix: String) -> String {
        let start = intro + "\n\n--- REQUEST ---\n"
        let end = "\n--- END REQUEST ---\n\n" + suffix
        let remaining = max(0, maxCharacters - start.count - end.count)
        let request = remaining > 0 ? bounded(description, limit: min(limit, remaining)) ?? "" : ""
        return start + request + end
    }

    /// The delivery contract every plugin prompt ends with. `compact` drops the
    /// requirements bullets (the reference page carries them) so a correction
    /// prompt has room for the findings.
    private static func pluginContract(host: String?, compact: Bool = false) -> String {
        let raw = host?.lowercased() ?? "example.com"
        let candidate = raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        let validHost = candidate.utf8.count <= 253 && labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        let site = validHost ? candidate : "example.com"
        let pluginID = "user." + site.prefix(95).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let requirements = compact ? "" : """

        Requirements:
        - ES2022; no imports, packages, polling or busy loops. Use luna.parseURL/luna.bytes; no URL, fetch or TextEncoder globals.
        - Never invent data. Use luna.fetch.json/doc and luna.html.parse/jsonLD. Bundle site parsing in the plugin. Keep redirect URLs and propagate browser-deferred.
        - Exports: omit produces/match; replace ingest hooks with export(input). Declare export:{kinds:["article"],input:"markdown",title:"Export"}; read input.text. Return {text}, {url}, {file}, delivery status or null. Settings/device APIs: see reference.

        """
        return """
        Deliver ONE file named "<name>.luna".
        \(binaryDeliveryInstructions)
        Source starts with the JSON header; register once. Stable [a-z0-9.-] id, name ≤40 chars, only needed capabilities.
        Host matches precede match.any; higher priority first. Bundled priority is 100: use 101 to override the same host, 0 for new sites. A valid result stops the walk.

        Article starter (adapt hosts and paths):
        /* luna-plugin
        {"id":"\(pluginID)","name":"Example","version":"1.0.0","api":1,"produces":["article"],"match":{"hosts":["\(site)","*.\(site)"]},"capabilities":["fetch","html"]}
        */
        luna.register({
          classify({url}) { return /\\/articles\\/[^/]+/.test(luna.parseURL(url)?.pathname || "") ? {kind:"article"} : false; },
          async ingest({url, page}) {
            const source = page?.html ? {text:page.html,url:page.url} : await luna.fetch(url);
            if (source.ok === false) return null;
            const doc = luna.html.parse(source.text, source.url);
            const body = doc.querySelector("article");
            if (!body || !body.textContent.trim()) return null;
            return {kind:"article", title:doc.title || url, html:body.innerHTML, baseURL:source.url};
          }
        });
        \(requirements)
        Check header, capabilities, hooks and Model fields. Article: title + html/document/transcription. Product: name + price:{amount:"12.34",currency:"USD"}. Media: assets:[{url,type:"video"|"image"|"gif"|"audio"}].
        """
    }

    /// Shared byte-level contract for recovery, plugin creation, and correction.
    private static let binaryDeliveryInstructions = """
    Create a BINARY attachment with your code tool, MIME application/octet-stream. source is the complete UTF-8 source below (max 1 MiB). Python: import zlib; data = bytes.fromhex('894c554e410d0a1a0a01') + zlib.compress(source.encode('utf-8')); write data in 'wb' mode. No plaintext, Base64, ZIP or code-block fallback. If binary attachments are unavailable, say so.
    """

    // MARK: - Helpers

    static func bounded(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
