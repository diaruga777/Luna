/* luna-plugin
{
  "id": "app.luna.facebook",
  "name": "Facebook",
  "version": "1.0.0",
  "api": 1,
  "description": "Resolves a Facebook video or reel from the page's own inline JSON.",
  "produces": ["media"],
  "match": { "hosts": ["facebook.com", "*.facebook.com", "fb.watch", "fb.com", "*.fb.com"] },
  "priority": 100,
  "capabilities": ["fetch", "html"]
}
*/

// The playable video URL lives in the page's inline JSON (`hd_src`,
// `browser_native_hd_url`, `playable_url`, …), never in the Open Graph tags: a
// walled reel's crawler `og:` tags expose only the poster still, so an og-first
// order would save a still from every video.
//
// Four stages, because Facebook serves the same permalink differently to each
// client:
//
//   1. `/plugins/video.php`, the video embed. It returns the real `hd_src` for a
//      public video even when the logged-out page is a login wall, and it needs
//      the DESKTOP user agent — the mobile one gets a sourceless page.
//   2. The desktop page itself.
//   3. The mobile page, whose `og:video` is the real (SD) MP4 for a reel, and
//      whose canonical link names the long-form video page when there is one.
//      `/reel/<id>` links and `fb.watch` short links 400 on the desktop agent.
//   4. The `facebookexternalhit` unfurl, which often omits `og:video` but keeps
//      `browser_native_*_url` in its inline JSON.
//
// Every stage runs against the STABLE content identity: Facebook changes its
// logged-out response when app-share tracking parameters are present.

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
        // Media resolution is a logged-out scrape: state carried over from an
        // earlier Facebook request can turn a public reel's response into a
        // consent or login wall.
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

/// The stable content URL every stage resolves against. Path-addressed
/// permalinks and `fb.watch` short links need no query; `/watch/?v=<id>` keeps
/// only `v`, which is content identity rather than share tracking.
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

/// The page's playable video, or an empty list. `og:image` is deliberately
/// ignored: for a Facebook video URL it is a poster, not downloadable media.
function assetsFromHTML(html, url) {
    const document = luna.html.parse(html, url);
    const poster = metaContent(document, "og:image");

    for (let i = 0; i < VIDEO_KEYS.length; i++) {
        const match = new RegExp("\"" + VIDEO_KEYS[i] + "\":\"(.*?)\"").exec(html);
        if (!match || !match[1]) { continue; }
        const asset = { url: unescapeURL(match[1]), type: "video" };
        if (poster) { asset.thumbnailURL = unescapeURL(poster); }
        asset.quality = i < 3 ? "hd" : "sd";
        return [asset];
    }
    const properties = ["og:video", "og:video:secure_url", "og:video:url"];
    for (let i = 0; i < properties.length; i++) {
        const content = metaContent(document, properties[i]);
        if (!content) { continue; }
        const asset = { url: unescapeURL(content), type: "video" };
        if (poster) { asset.thumbnailURL = unescapeURL(poster); }
        return [asset];
    }
    return [];
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

/// Facebook signs a CDN URL with `oe`, a hex epoch.
function expirySeconds(rawURL) {
    const parsed = luna.parseURL(rawURL);
    if (!parsed) { return null; }
    const value = parseInt(parsed.searchParams.get("oe") || "", 16);
    return isNaN(value) || value <= 0 ? null : value;
}

function model(assets, itemID) {
    const result = { kind: "media", platform: "facebook", assets: assets };
    if (itemID) { result.itemId = itemID; }
    const expiry = expirySeconds(assets[0].url);
    if (expiry) { result.expiresAt = expiry; }
    return result;
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

luna.register({
    classify({ url, intent }) {
        // A transcribe intent belongs to the transcript plugin, which sits
        // below this one in the walk.
        if (intent === "transcribe") { return false; }
        const parsed = luna.parseURL(url);
        if (!parsed) { return false; }
        const itemID = itemIDOf(parsed);
        return itemID ? { kind: "media", itemId: itemID } : { kind: "media" };
    },

    async ingest({ url, claim }) {
        const stable = resolutionURL(url);
        const itemID = claim && claim.itemId;

        const embedHTML = await getText(
            pageRequest(videoPluginURL(url), DESKTOP_USER_AGENT));
        if (embedHTML) {
            const assets = assetsFromHTML(embedHTML, stable);
            if (assets.length > 0) { return model(assets, itemID); }
        }

        const desktopHTML = await getText(pageRequest(stable, DESKTOP_USER_AGENT));
        if (desktopHTML) {
            const assets = assetsFromHTML(desktopHTML, stable);
            if (assets.length > 0) { return model(assets, itemID); }
        }

        const mobileHTML = await getText(pageRequest(stable, "safari"));
        if (mobileHTML) {
            const canonical = canonicalVideoURL(mobileHTML, stable);
            if (canonical && canonical !== stable) {
                const canonicalHTML = await getText(
                    pageRequest(canonical, DESKTOP_USER_AGENT));
                if (canonicalHTML) {
                    const assets = assetsFromHTML(canonicalHTML, canonical);
                    if (assets.length > 0) { return model(assets, itemID); }
                }
            }
            const assets = assetsFromHTML(mobileHTML, stable);
            if (assets.length > 0) { return model(assets, itemID); }
        }

        const unfurlHTML = await getText(pageRequest(stable, "facebookbot"));
        if (!unfurlHTML) { return null; }
        const assets = assetsFromHTML(unfurlHTML, stable);
        return assets.length > 0 ? model(assets, itemID) : null;
    },
});
