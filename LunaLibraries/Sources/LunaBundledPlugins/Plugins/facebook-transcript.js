/* luna-plugin
{
  "id": "app.luna.facebook.transcript",
  "name": "Facebook transcript",
  "version": "1.0.0",
  "api": 1,
  "description": "Reads a Facebook video or reel as an article by transcribing the video's audio.",
  "produces": ["article"],
  "match": { "hosts": ["facebook.com", "*.facebook.com", "fb.watch", "fb.com", "*.fb.com"] },
  "priority": 90,
  "capabilities": ["fetch", "html"]
}
*/

// The transcript twin of `facebook.js`. Facebook's logged-out pages publish no
// captions and no audio-only file, so the source is the playable MP4 the
// media plugin finds — HD first, then SD — which Luna downloads, transcribes
// and deletes. The page's Open Graph title and description lead the article.
// `facebook.js` outranks this plugin and declines a transcribe intent.

const DESKTOP_USER_AGENT =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15";

/// Playable-URL keys in quality order. HD first, so the best available leg wins.
const VIDEO_KEYS = [
    "browser_native_hd_url", "playable_url_quality_hd", "hd_src",
    "browser_native_sd_url", "playable_url", "sd_src",
];

const FACEBOOK_HOSTS = ["facebook.com", "fb.watch", "fb.com"];

async function getText(request) {
    try {
        const response = await luna.fetch(request);
        if (!response.ok || typeof response.text !== "string") { return null; }
        return response.text;
    } catch (error) {
        return null;
    }
}

function pageRequest(url, userAgent) {
    return {
        url: url,
        userAgent: userAgent,
        headers: {
            Accept: "text/html,application/xhtml+xml",
            "Accept-Language": "en-US,en;q=0.9",
        },
        cookies: "none",
    };
}

function isFacebookURL(rawURL) {
    const parsed = luna.parseURL(rawURL);
    if (!parsed) { return false; }
    const host = parsed.hostname;
    return FACEBOOK_HOSTS.some(function (candidate) {
        return host === candidate || host.endsWith("." + candidate);
    });
}

/// The stable content URL every stage resolves against.
function resolutionURL(rawURL) {
    const parsed = luna.parseURL(rawURL);
    if (!parsed) { return rawURL; }
    const videoID = parsed.searchParams.get("v");
    return parsed.protocol + "//" + parsed.host + parsed.pathname
        + (videoID ? "?v=" + encodeURIComponent(videoID) : "");
}

function videoPluginURL(rawURL) {
    return "https://www.facebook.com/plugins/video.php?href="
        + encodeURIComponent(resolutionURL(rawURL));
}

/// Unescapes the JSON-encoded URLs Facebook embeds in its inline JSON.
function unescapeURL(value) {
    let result = value;
    try {
        result = JSON.parse("\"" + value + "\"");
    } catch (error) {
        // Not a JSON string literal; the replacements below still apply.
    }
    return result
        .split("\\u0026").join("&")
        .split("\\u0025").join("%")
        .split("\\/").join("/")
        .split("&amp;").join("&");
}

function metaContent(document, name) {
    const node = document.querySelector(
        "meta[property=\"" + name + "\"], meta[name=\"" + name + "\"]");
    if (!node) { return null; }
    const content = node.getAttribute("content");
    return (typeof content === "string" && content.length > 0) ? content : null;
}

/// What the page says about its video: the playable URL (or null) plus the
/// title and description its Open Graph tags carry.
function pageVideo(html, url) {
    const document = luna.html.parse(html, url);
    const found = {
        url: null,
        title: metaContent(document, "og:title"),
        description: metaContent(document, "og:description"),
    };
    for (let i = 0; i < VIDEO_KEYS.length; i++) {
        const match = new RegExp("\"" + VIDEO_KEYS[i] + "\":\"(.*?)\"").exec(html);
        if (match && match[1]) {
            found.url = unescapeURL(match[1]);
            return found;
        }
    }
    const properties = ["og:video", "og:video:secure_url", "og:video:url"];
    for (let i = 0; i < properties.length; i++) {
        const content = metaContent(document, properties[i]);
        if (content) {
            found.url = unescapeURL(content);
            return found;
        }
    }
    return found;
}

/// The long-form video URL this page belongs to, when it names one.
function canonicalVideoURL(html, url) {
    const document = luna.html.parse(html, url);
    const candidates = [];
    const canonical = document.querySelector("link[rel=\"canonical\"]");
    if (canonical) { candidates.push(canonical.getAttribute("href")); }
    candidates.push(metaContent(document, "og:url"));
    const embedded = /oembed_video\?url=([^"&]+)/.exec(html);
    if (embedded && embedded[1]) { candidates.push(decodeURIComponent(embedded[1])); }

    for (let i = 0; i < candidates.length; i++) {
        const candidate = candidates[i];
        if (typeof candidate !== "string" || candidate.length === 0) { continue; }
        const resolved = unescapeURL(candidate);
        if (isFacebookURL(resolved)) { return resolved; }
    }
    return null;
}

/// Facebook signs a CDN URL with `oe`, a hex epoch, in seconds.
function expirySeconds(rawURL) {
    const parsed = luna.parseURL(rawURL);
    if (!parsed) { return null; }
    const value = parseInt(parsed.searchParams.get("oe") || "", 16);
    return isNaN(value) || value <= 0 ? null : value;
}

/// The video id from `?v=` or a `/reel|/videos/<id>` path segment.
function itemIDOf(parsed) {
    const videoID = parsed.searchParams.get("v");
    if (videoID) { return videoID; }
    const parts = String(parsed.pathname || "").split("/").filter(function (part) {
        return part.length > 0;
    });
    const keys = ["reel", "videos"];
    for (let i = 0; i < parts.length; i++) {
        if (keys.indexOf(parts[i]) >= 0 && parts[i + 1]) { return parts[i + 1]; }
    }
    return null;
}

// MARK: - Text

function escapeHTML(text) {
    return String(text)
        .split("&").join("&amp;")
        .split("<").join("&lt;")
        .split(">").join("&gt;")
        .split("\"").join("&quot;");
}

function decodeEntities(text) {
    return String(text)
        .replace(/&#(\d+);/g, function (whole, code) { return String.fromCharCode(Number(code)); })
        .replace(/&#x([0-9a-fA-F]+);/g, function (whole, code) {
            return String.fromCharCode(parseInt(code, 16));
        })
        .split("&nbsp;").join(" ")
        .split("&quot;").join("\"")
        .split("&#39;").join("'")
        .split("&apos;").join("'")
        .split("&lt;").join("<")
        .split("&gt;").join(">")
        .split("&amp;").join("&");
}

/// Free text as escaped paragraphs, split at blank lines.
function textHTML(text) {
    const blocks = decodeEntities(String(text || "")).split(/\r?\n\s*\r?\n/);
    const paragraphs = [];
    blocks.forEach(function (block) {
        const flat = block.replace(/\s+/g, " ").trim();
        if (flat.length > 0) { paragraphs.push("<p>" + escapeHTML(flat) + "</p>"); }
    });
    return paragraphs.join("\n");
}

function model(video, itemID) {
    const title = video.title ? decodeEntities(video.title).replace(/\s+/g, " ").trim() : "";
    const result = {
        kind: "article",
        title: title.length > 0 ? title.slice(0, 300) : "Facebook " + (itemID || "video"),
        transcription: { url: video.url, type: "video" },
    };
    const html = textHTML(video.description);
    if (html.length > 0) { result.html = html; }
    const expiry = expirySeconds(video.url);
    if (expiry) { result.transcription.expiresAt = expiry; }
    return result;
}

luna.register({
    classify({ url }) {
        const parsed = luna.parseURL(url);
        if (!parsed) { return false; }
        const itemID = itemIDOf(parsed);
        return itemID ? { kind: "article", itemId: itemID } : { kind: "article" };
    },

    async ingest({ url, claim }) {
        const stable = resolutionURL(url);
        const itemID = claim && claim.itemId;

        const embedHTML = await getText(
            pageRequest(videoPluginURL(url), DESKTOP_USER_AGENT));
        if (embedHTML) {
            const video = pageVideo(embedHTML, stable);
            if (video.url) { return model(video, itemID); }
        }

        const desktopHTML = await getText(pageRequest(stable, DESKTOP_USER_AGENT));
        if (desktopHTML) {
            const video = pageVideo(desktopHTML, stable);
            if (video.url) { return model(video, itemID); }
        }

        const mobileHTML = await getText(pageRequest(stable, "safari"));
        if (mobileHTML) {
            const canonical = canonicalVideoURL(mobileHTML, stable);
            if (canonical && canonical !== stable) {
                const canonicalHTML = await getText(
                    pageRequest(canonical, DESKTOP_USER_AGENT));
                if (canonicalHTML) {
                    const video = pageVideo(canonicalHTML, canonical);
                    if (video.url) { return model(video, itemID); }
                }
            }
            const video = pageVideo(mobileHTML, stable);
            if (video.url) { return model(video, itemID); }
        }

        const unfurlHTML = await getText(pageRequest(stable, "facebookbot"));
        if (!unfurlHTML) { return null; }
        const video = pageVideo(unfurlHTML, stable);
        return video.url ? model(video, itemID) : null;
    },
});
