/* luna-plugin
{
  "id": "app.luna.nytimes",
  "name": "New York Times",
  "version": "1.0.0",
  "api": 1,
  "description": "Reads New York Times articles through the trailing-dot hostname and Luna's shared article extractor.",
  "produces": ["article"],
  "match": {
    "hosts": ["nytimes.com", "*.nytimes.com", "nyt.com", "*.nyt.com"]
  },
  "priority": 100,
  "capabilities": ["fetch", "html"]
}
*/

function isNYTHost(host) {
    const normalized = String(host || "").toLowerCase().replace(/\.$/, "");
    return normalized === "nytimes.com" || normalized.endsWith(".nytimes.com")
        || normalized === "nyt.com" || normalized.endsWith(".nyt.com");
}

function trailingDotURL(url) {
    const parsed = luna.parseURL(url);
    if (!parsed || parsed.protocol !== "https:" || !isNYTHost(parsed.hostname)) { return null; }
    const authority = parsed.protocol + "//" + parsed.host;
    if (!parsed.href.startsWith(authority)) { return null; }
    const hostname = parsed.hostname.endsWith(".") ? parsed.hostname : parsed.hostname + ".";
    const dottedAuthority = parsed.protocol + "//" + hostname
        + (parsed.port ? ":" + parsed.port : "");
    return dottedAuthority + parsed.href.slice(authority.length);
}

function looksLikeConsentOrPrivacyPage(article) {
    const title = String(article.title || "").trim();
    if (/\b(privacy|terms of (service|use)|cookie|consent|data use)\b/i.test(title)) {
        return true;
    }
    const text = String(article.text || "").trim();
    return text.length < 1200
        || /\b(data privacy terms|privacy policy|terms of service|cookie policy)\b/i.test(text);
}

luna.register({
    classify({ url }) {
        try {
            const parsed = luna.parseURL(url);
            return isNYTHost(parsed.hostname) ? { kind: "article", confidence: 1 } : false;
        } catch (_) {
            return false;
        }
    },

    async ingest({ url }) {
        const requestURL = trailingDotURL(url);
        if (!requestURL) { return null; }

        let response;
        try {
            response = await luna.fetch({
                url: requestURL,
                userAgent: "safari",
                cookies: "none",
                timeout: 20,
                headers: { Accept: "text/html,application/xhtml+xml" },
            });
        } catch (_) {
            return null;
        }
        if (!response.ok || typeof response.text !== "string" || response.text.length === 0) {
            return null;
        }

        let article;
        try {
            // Resolve relative images and links against the canonical URL, not
            // the transport-only trailing-dot spelling.
            article = await luna.html.article(response.text, url);
        } catch (_) {
            return null;
        }
        if (!article || looksLikeConsentOrPrivacyPage(article)) { return null; }

        return {
            kind: "article",
            title: article.title,
            author: article.author,
            publishedAt: article.publishedAt,
            html: article.html,
            baseURL: url,
            leadImageURL: article.leadImageURL,
            excerpt: article.excerpt,
        };
    },
});
