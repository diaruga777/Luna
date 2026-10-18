/* luna-plugin
{
  "id": "app.luna.instagram",
  "name": "Instagram",
  "version": "1.0.0",
  "api": 1,
  "description": "Resolves an Instagram post, reel or carousel through three keyless sources.",
  "produces": ["media"],
  "match": { "hosts": ["instagram.com", "*.instagram.com", "instagr.am", "*.instagr.am"] },
  "priority": 100,
  "capabilities": ["fetch", "html"]
}
*/

// Three keyless sources, in an order that exists to keep a VIDEO from resolving
// to its cover frame: Instagram hands out that still freely and the playable
// MP4 from one endpoint at a time.
//
//   1. The post page as served to a search crawler. Its `data-sjs` scripts carry
//      `xig_polaris_media.if_not_gated_logged_out`, an api-v1-shaped node with
//      `video_versions`, `image_versions2` and `carousel_media`.
//   2. The web client's persisted GraphQL query. Since 2026-09 the logged-out
//      endpoint answers 401 `require_login`, and it stays in the ladder because
//      it answers again the moment that wall lifts.
//   3. The embed page, which still serves stills and carousels.
//
// A source that says "this is a video" without naming a playable URL sets
// `declaresVideo`. While that stands, the still-only sources below are barred:
// returning the cover frame there is what made a saved reel come back as an
// image.

/// `PolarisPostActionLoadPostQueryQuery` — the query Instagram's own web post
/// page issues, and the only keyless one that returns `video_url`.
const POST_DOCUMENT_ID = "10015901848480474";
/// The public application id instagram.com's own JS sends. Not a credential;
/// the logged-out GraphQL endpoint just expects the header.
const WEB_APP_ID = "936619743392459";

const MEDIA_PATH_KINDS = ["p", "reel", "reels", "tv"];

async function getText(request) {
    try {
        const response = await luna.fetch(request);
        if (!response.ok || typeof response.text !== "string") { return null; }
        return response.text;
    } catch (error) {
        return null;
    }
}

/// The shortcode `/(p|reel|reels|tv)/<code>` names, or null.
function shortcodeOf(parsed) {
    const parts = String(parsed.pathname || "").split("/").filter(function (part) {
        return part.length > 0;
    });
    for (let i = 0; i < parts.length; i++) {
        if (MEDIA_PATH_KINDS.indexOf(parts[i]) >= 0 && parts[i + 1]) {
            return parts[i + 1];
        }
    }
    return null;
}

/// Instagram signs a CDN URL with `oe`, a hex epoch. The engine re-runs this
/// plugin once it passes.
function expirySeconds(rawURL) {
    const parsed = luna.parseURL(rawURL);
    if (!parsed) { return null; }
    const value = parseInt(parsed.searchParams.get("oe") || "", 16);
    return isNaN(value) || value <= 0 ? null : value;
}

function post(assets, declaresVideo) {
    return { assets: assets, declaresVideo: declaresVideo };
}

// MARK: - The crawler page's api-v1 node

/// `media_type` 1 is an image, 2 a video, 8 a carousel.
function apiDeclaresVideo(media) {
    if (typeof media.media_type === "number") { return media.media_type === 2; }
    return media.video_versions !== undefined && media.video_versions !== null;
}

/// One asset from an api-v1 node. A video node with no `video_versions` yields
/// NOTHING rather than its still: that image is the cover frame, not the reel.
function apiAsset(media) {
    const candidates = (media.image_versions2 && media.image_versions2.candidates) || [];
    const still = (candidates[0] && typeof candidates[0].url === "string")
        ? candidates[0].url : null;
    if (apiDeclaresVideo(media)) {
        const versions = Array.isArray(media.video_versions) ? media.video_versions : [];
        const version = versions[0];
        if (!version || typeof version.url !== "string") { return null; }
        const asset = { url: version.url, type: "video" };
        if (still) { asset.thumbnailURL = still; }
        if (typeof version.height === "number" && version.height > 0) {
            asset.quality = version.height + "p";
        }
        return asset;
    }
    if (!still) { return null; }
    return { url: still, type: "image" };
}

function apiPost(media) {
    const children = Array.isArray(media.carousel_media) ? media.carousel_media : [];
    if (children.length > 0) {
        return post(
            children.map(apiAsset).filter(Boolean),
            children.some(apiDeclaresVideo));
    }
    const asset = apiAsset(media);
    return post(asset ? [asset] : [], apiDeclaresVideo(media));
}

/// Depth-first search for the first value under `key`. The crawler page nests
/// the media node inside a require/bbox scaffold whose shape shifts between page
/// builds, so nothing above the key itself can be pinned.
function firstValue(object, key) {
    if (Array.isArray(object)) {
        for (let i = 0; i < object.length; i++) {
            const found = firstValue(object[i], key);
            if (found !== undefined) { return found; }
        }
        return undefined;
    }
    if (object && typeof object === "object") {
        if (Object.prototype.hasOwnProperty.call(object, key)) { return object[key]; }
        const names = Object.keys(object);
        for (let i = 0; i < names.length; i++) {
            const found = firstValue(object[names[i]], key);
            if (found !== undefined) { return found; }
        }
    }
    return undefined;
}

/// Every JSON script body on the page. `luna.html.jsonScripts` reads the typed
/// ones; the untyped scan catches a build that drops the type attribute.
function scriptBodies(document) {
    const bodies = luna.html.jsonScripts(document).slice();
    const scripts = document.querySelectorAll("script");
    for (let i = 0; i < scripts.length; i++) {
        const source = scripts[i].innerHTML;
        if (source.indexOf("xig_polaris_media") < 0) { continue; }
        try {
            bodies.push(JSON.parse(source));
        } catch (error) {
            // One malformed block must not cost the page's other scripts.
        }
    }
    return bodies;
}

/// The post the crawler-served page describes, or null when no script carries a
/// logged-out media node.
function postFromCrawlerPage(html, url) {
    const bodies = scriptBodies(luna.html.parse(html, url));
    let fallback = null;
    for (let i = 0; i < bodies.length; i++) {
        const wrapper = firstValue(bodies[i], "xig_polaris_media");
        const media = wrapper && wrapper.if_not_gated_logged_out;
        if (!media) { continue; }
        const candidate = apiPost(media);
        if (candidate.assets.length > 0 || candidate.declaresVideo) { return candidate; }
        if (!fallback) { fallback = candidate; }
    }
    return fallback;
}

// MARK: - The shortcode-media node (GraphQL and embed)

/// `__typename` is `GraphVideo` on the embed payload and `XDTGraphVideo` on the
/// GraphQL one, so video detection matches the suffix.
function nodeDeclaresVideo(node) {
    if (typeof node.is_video === "boolean") { return node.is_video; }
    return /GraphVideo$/.test(String(node.__typename || ""));
}

/// A video node with no `video_url` yields NOTHING rather than its
/// `display_url`: that still is the reel's cover frame. The poster is still
/// reachable — it rides a resolved video as `thumbnailURL`.
function nodeAsset(node) {
    if (nodeDeclaresVideo(node)) {
        if (typeof node.video_url !== "string") { return null; }
        const asset = { url: node.video_url, type: "video" };
        if (typeof node.display_url === "string") { asset.thumbnailURL = node.display_url; }
        return asset;
    }
    if (typeof node.display_url !== "string") { return null; }
    return { url: node.display_url, type: "image" };
}

function postFromShortcodeMedia(media) {
    const sidecar = media.edge_sidecar_to_children;
    const edges = (sidecar && Array.isArray(sidecar.edges)) ? sidecar.edges : [];
    const children = edges.map(function (edge) { return edge.node; }).filter(Boolean);
    if (children.length > 0) {
        return post(
            children.map(nodeAsset).filter(Boolean),
            children.some(nodeDeclaresVideo));
    }
    const asset = nodeAsset(media);
    return post(asset ? [asset] : [], nodeDeclaresVideo(media));
}

/// The embed page's `contextJSON` — a JSON string literal holding
/// `gql_data.shortcode_media`.
function postFromEmbedHTML(html) {
    const marker = html.indexOf("contextJSON");
    if (marker < 0) { return null; }
    const afterMarker = html.slice(marker + "contextJSON".length);
    const colon = afterMarker.indexOf(":");
    if (colon < 0) { return null; }
    const afterColon = afterMarker.slice(colon + 1);
    const openQuote = afterColon.indexOf("\"");
    if (openQuote < 0) { return null; }

    // Walk the string literal, honouring backslash escapes, to its closing
    // quote.
    let literal = "\"";
    let index = openQuote + 1;
    while (index < afterColon.length) {
        const character = afterColon.charAt(index);
        literal += character;
        if (character === "\\") {
            index += 1;
            if (index >= afterColon.length) { break; }
            literal += afterColon.charAt(index);
        } else if (character === "\"") {
            break;
        }
        index += 1;
    }
    try {
        const inner = JSON.parse(literal);
        const context = JSON.parse(inner);
        const media = context.gql_data && context.gql_data.shortcode_media;
        return media ? postFromShortcodeMedia(media) : null;
    } catch (error) {
        return null;
    }
}

// MARK: - Older inline markup

/// Unescapes the JSON- and HTML-encoded URLs Instagram embeds in markup.
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

function firstGroup(text, pattern) {
    const match = pattern.exec(text);
    return (match && match[1]) ? match[1] : null;
}

function metaContent(document, name) {
    const node = document.querySelector(
        "meta[property=\"" + name + "\"], meta[name=\"" + name + "\"]");
    if (!node) { return null; }
    const content = node.getAttribute("content");
    return (typeof content === "string" && content.length > 0) ? content : null;
}

/// Assets from whatever the page inlines: a video URL first, then a still.
/// Older embed markup occasionally carries an unescaped `video_url`.
function assetsFromHTML(html, url) {
    const document = luna.html.parse(html, url);
    const poster = metaContent(document, "og:image");

    const inlineVideo = firstGroup(html, /"video_url":"(.*?)"/);
    const video = inlineVideo
        || metaContent(document, "og:video")
        || metaContent(document, "og:video:secure_url");
    if (video) {
        const asset = { url: unescapeURL(video), type: "video" };
        if (poster) { asset.thumbnailURL = unescapeURL(poster); }
        return [asset];
    }

    const inlineImage = firstGroup(html, /"display_url":"(.*?)"/)
        || firstGroup(html, /class="EmbeddedMediaImage"[^>]*?src="(.*?)"/);
    const image = inlineImage || poster;
    if (image) { return [{ url: unescapeURL(image), type: "image" }]; }
    return [];
}

// MARK: - The ladder

function model(assets, shortcode) {
    const result = {
        kind: "media", platform: "instagram", itemId: shortcode, assets: assets,
    };
    const expiry = expirySeconds(assets[0].url);
    if (expiry) { result.expiresAt = expiry; }
    return result;
}

luna.register({
    classify({ url, intent }) {
        // A transcribe intent belongs to the transcript plugin, which sits
        // below this one in the walk.
        if (intent === "transcribe") { return false; }
        const parsed = luna.parseURL(url);
        if (!parsed) { return false; }
        const shortcode = shortcodeOf(parsed);
        return shortcode ? { kind: "media", itemId: shortcode } : false;
    },

    async ingest({ url, claim }) {
        const shortcode = claim && claim.itemId;
        if (!shortcode) { return null; }
        let declaredVideo = false;

        // `/p/{code}/` serves reels as well as posts. Cookie-free, because
        // state carried over from an earlier request can turn a public post's
        // response into a login wall.
        const pageHTML = await getText({
            url: "https://www.instagram.com/p/" + shortcode + "/",
            userAgent: "googlebot",
            cookies: "none",
            headers: { Accept: "text/html,application/xhtml+xml" },
        });
        if (pageHTML) {
            const page = postFromCrawlerPage(pageHTML, url);
            if (page) {
                if (page.assets.length > 0) { return model(page.assets, shortcode); }
                // The query below can still name a URL for a video this page
                // would not; only the still-only stages are barred.
                declaredVideo = page.declaresVideo;
            }
        }

        const queryText = await getText({
            url: "https://www.instagram.com/graphql/query/?doc_id=" + POST_DOCUMENT_ID
                + "&variables=" + encodeURIComponent("{\"shortcode\":\"" + shortcode + "\"}"),
            userAgent: "safari",
            cookies: "none",
            headers: { Accept: "application/json", "X-IG-App-ID": WEB_APP_ID },
        });
        if (queryText) {
            let media = null;
            try {
                const payload = JSON.parse(queryText);
                media = payload.data && payload.data.xdt_shortcode_media;
            } catch (error) {
                media = null;
            }
            if (media) {
                const graph = postFromShortcodeMedia(media);
                if (graph.assets.length > 0) { return model(graph.assets, shortcode); }
                // A video the query could not produce a URL for: the sources
                // below can only offer its poster, so stop rather than pass a
                // still off as the reel.
                if (graph.declaresVideo) { return null; }
            }
        }

        const embedHTML = await getText({
            url: "https://www.instagram.com/p/" + shortcode + "/embed/captioned/",
            userAgent: "safari",
            headers: { Accept: "text/html,application/xhtml+xml" },
        });
        if (embedHTML) {
            let embedDeclaredVideo = false;
            const embed = postFromEmbedHTML(embedHTML);
            if (embed) {
                if (embed.assets.length > 0) { return model(embed.assets, shortcode); }
                embedDeclaredVideo = embed.declaresVideo;
            }
            const legacy = assetsFromHTML(embedHTML, url);
            if (legacy.length > 0 && (!embedDeclaredVideo || legacy[0].type === "video")) {
                return model(legacy, shortcode);
            }
            declaredVideo = declaredVideo || embedDeclaredVideo;
        }

        // The post page's `og:` tags are image-only for a walled video post —
        // better than nothing for a still, never right for a reel.
        if (declaredVideo) { return null; }
        const unfurlHTML = await getText({
            url: url,
            userAgent: "facebookbot",
            headers: { Accept: "text/html,application/xhtml+xml" },
        });
        if (!unfurlHTML) { return null; }
        const assets = assetsFromHTML(unfurlHTML, url);
        return assets.length > 0 ? model(assets, shortcode) : null;
    },
});
