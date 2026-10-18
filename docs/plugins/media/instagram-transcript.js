/* luna-plugin
{
  "id": "app.luna.instagram.transcript",
  "name": "Instagram transcript",
  "version": "1.0.0",
  "api": 1,
  "description": "Reads an Instagram reel or video post as an article by transcribing the video's audio.",
  "produces": ["article"],
  "match": { "hosts": ["instagram.com", "*.instagram.com", "instagr.am", "*.instagr.am"] },
  "priority": 90,
  "capabilities": ["fetch", "html"]
}
*/

// The transcript twin of `instagram.js`. Instagram's keyless sources publish
// no captions and no audio-only file — `video_versions` and `video_url` name
// muxed MP4s — so the source is the reel's MP4, which Luna downloads,
// transcribes and deletes. The post's caption leads the article. The ladder
// and its video-versus-still guard are the media plugin's; a post that
// resolves to stills only is declined. `instagram.js` outranks this plugin and
// declines a transcribe intent.

const POST_DOCUMENT_ID = "10015901848480474";
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

/// Instagram signs a CDN URL with `oe`, a hex epoch, in seconds.
function expirySeconds(rawURL) {
    const parsed = luna.parseURL(rawURL);
    if (!parsed) { return null; }
    const value = parseInt(parsed.searchParams.get("oe") || "", 16);
    return isNaN(value) || value <= 0 ? null : value;
}

/// What a source said about the post: the first video URL (or null), whether
/// it declared a video it could not name, and the caption and author it carried.
function found(videoURL, declaresVideo, caption, author) {
    return {
        videoURL: videoURL || null,
        declaresVideo: !!declaresVideo,
        caption: typeof caption === "string" ? caption : null,
        author: typeof author === "string" ? author : null,
    };
}

// MARK: - The crawler page's api-v1 node

function apiDeclaresVideo(media) {
    if (typeof media.media_type === "number") { return media.media_type === 2; }
    return media.video_versions !== undefined && media.video_versions !== null;
}

function apiVideoURL(media) {
    if (!apiDeclaresVideo(media)) { return null; }
    const versions = Array.isArray(media.video_versions) ? media.video_versions : [];
    const version = versions[0];
    return (version && typeof version.url === "string") ? version.url : null;
}

function apiPost(media) {
    const caption = media.caption && media.caption.text;
    const author = media.user && (media.user.full_name || media.user.username);
    const children = Array.isArray(media.carousel_media) ? media.carousel_media : [];
    if (children.length > 0) {
        let url = null;
        children.forEach(function (child) { if (!url) { url = apiVideoURL(child); } });
        return found(url, children.some(apiDeclaresVideo), caption, author);
    }
    return found(apiVideoURL(media), apiDeclaresVideo(media), caption, author);
}

function firstValue(object, key) {
    if (Array.isArray(object)) {
        for (let i = 0; i < object.length; i++) {
            const result = firstValue(object[i], key);
            if (result !== undefined) { return result; }
        }
        return undefined;
    }
    if (object && typeof object === "object") {
        if (Object.prototype.hasOwnProperty.call(object, key)) { return object[key]; }
        const names = Object.keys(object);
        for (let i = 0; i < names.length; i++) {
            const result = firstValue(object[names[i]], key);
            if (result !== undefined) { return result; }
        }
    }
    return undefined;
}

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

function postFromCrawlerPage(html, url) {
    const bodies = scriptBodies(luna.html.parse(html, url));
    let fallback = null;
    for (let i = 0; i < bodies.length; i++) {
        const wrapper = firstValue(bodies[i], "xig_polaris_media");
        const media = wrapper && wrapper.if_not_gated_logged_out;
        if (!media) { continue; }
        const candidate = apiPost(media);
        if (candidate.videoURL || candidate.declaresVideo) { return candidate; }
        if (!fallback) { fallback = candidate; }
    }
    return fallback;
}

// MARK: - The shortcode-media node (GraphQL and embed)

function nodeDeclaresVideo(node) {
    if (typeof node.is_video === "boolean") { return node.is_video; }
    return /GraphVideo$/.test(String(node.__typename || ""));
}

function nodeVideoURL(node) {
    if (!nodeDeclaresVideo(node)) { return null; }
    return typeof node.video_url === "string" ? node.video_url : null;
}

function nodeCaption(media) {
    const edges = media.edge_media_to_caption && media.edge_media_to_caption.edges;
    const node = Array.isArray(edges) && edges[0] ? edges[0].node : null;
    return node && typeof node.text === "string" ? node.text : null;
}

function postFromShortcodeMedia(media) {
    const author = media.owner && (media.owner.full_name || media.owner.username);
    const sidecar = media.edge_sidecar_to_children;
    const edges = (sidecar && Array.isArray(sidecar.edges)) ? sidecar.edges : [];
    const children = edges.map(function (edge) { return edge.node; }).filter(Boolean);
    if (children.length > 0) {
        let url = null;
        children.forEach(function (child) { if (!url) { url = nodeVideoURL(child); } });
        return found(url, children.some(nodeDeclaresVideo), nodeCaption(media), author);
    }
    return found(nodeVideoURL(media), nodeDeclaresVideo(media), nodeCaption(media), author);
}

function postFromEmbedHTML(html) {
    const marker = html.indexOf("contextJSON");
    if (marker < 0) { return null; }
    const afterMarker = html.slice(marker + "contextJSON".length);
    const colon = afterMarker.indexOf(":");
    if (colon < 0) { return null; }
    const afterColon = afterMarker.slice(colon + 1);
    const openQuote = afterColon.indexOf("\"");
    if (openQuote < 0) { return null; }

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

/// The video the page inlines, with the description its Open Graph tags carry.
function postFromHTML(html, url) {
    const document = luna.html.parse(html, url);
    const inlineVideo = firstGroup(html, /"video_url":"(.*?)"/);
    const video = inlineVideo
        || metaContent(document, "og:video")
        || metaContent(document, "og:video:secure_url");
    return found(
        video ? unescapeURL(video) : null, !!video,
        metaContent(document, "og:description"), null);
}

// MARK: - Text

function escapeHTML(text) {
    return String(text)
        .split("&").join("&amp;")
        .split("<").join("&lt;")
        .split(">").join("&gt;")
        .split("\"").join("&quot;");
}

/// Free text as escaped paragraphs, one per line group.
function textHTML(text) {
    const blocks = String(text || "").split(/\r?\n\s*\r?\n|\r?\n/);
    const paragraphs = [];
    blocks.forEach(function (block) {
        const flat = block.replace(/\s+/g, " ").trim();
        if (flat.length > 0) { paragraphs.push("<p>" + escapeHTML(flat) + "</p>"); }
    });
    return paragraphs.join("\n");
}

function model(post, shortcode) {
    const caption = (post.caption || "").replace(/\s+/g, " ").trim();
    const result = {
        kind: "article",
        title: caption.length > 0 ? caption.slice(0, 300) : "Instagram " + shortcode,
        transcription: { url: post.videoURL, type: "video" },
    };
    const html = textHTML(post.caption);
    if (html.length > 0) { result.html = html; }
    if (post.author && post.author.length > 0) { result.author = post.author.slice(0, 300); }
    const expiry = expirySeconds(post.videoURL);
    if (expiry) { result.transcription.expiresAt = expiry; }
    return result;
}

luna.register({
    classify({ url }) {
        const parsed = luna.parseURL(url);
        if (!parsed) { return false; }
        const shortcode = shortcodeOf(parsed);
        return shortcode ? { kind: "article", itemId: shortcode } : false;
    },

    async ingest({ url, claim }) {
        const shortcode = claim && claim.itemId;
        if (!shortcode) { return null; }

        const pageHTML = await getText({
            url: "https://www.instagram.com/p/" + shortcode + "/",
            userAgent: "googlebot",
            cookies: "none",
            headers: { Accept: "text/html,application/xhtml+xml" },
        });
        if (pageHTML) {
            const page = postFromCrawlerPage(pageHTML, url);
            if (page && page.videoURL) { return model(page, shortcode); }
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
                if (graph.videoURL) { return model(graph, shortcode); }
                // A video the query names no URL for: the sources below offer
                // only its poster, so stop rather than fetch a still.
                if (graph.declaresVideo) { return null; }
            }
        }

        const embedHTML = await getText({
            url: "https://www.instagram.com/p/" + shortcode + "/embed/captioned/",
            userAgent: "safari",
            headers: { Accept: "text/html,application/xhtml+xml" },
        });
        if (embedHTML) {
            const embed = postFromEmbedHTML(embedHTML);
            if (embed && embed.videoURL) { return model(embed, shortcode); }
            const legacy = postFromHTML(embedHTML, url);
            if (legacy.videoURL) { return model(legacy, shortcode); }
        }

        const unfurlHTML = await getText({
            url: url,
            userAgent: "facebookbot",
            headers: { Accept: "text/html,application/xhtml+xml" },
        });
        if (!unfurlHTML) { return null; }
        const unfurl = postFromHTML(unfurlHTML, url);
        return unfurl.videoURL ? model(unfurl, shortcode) : null;
    },
});
