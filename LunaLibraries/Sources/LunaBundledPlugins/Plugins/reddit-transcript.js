/* luna-plugin
{
  "id": "app.luna.reddit.transcript",
  "name": "Reddit transcript",
  "version": "1.0.0",
  "api": 1,
  "description": "Reads a Reddit-hosted video as an article by transcribing its separate audio track.",
  "produces": ["article"],
  "match": { "hosts": ["reddit.com", "*.reddit.com", "redd.it", "*.redd.it"] },
  "priority": 90,
  "capabilities": ["fetch"]
}
*/

// The transcript twin of `reddit.js`. Reddit publishes no captions, but a
// video with sound keeps its audio as a separate DASH file — the sibling
// `audio` path the media plugin rides as `audioURL` — so the transcription
// source is that small file alone, never the video. A silent video has nothing
// to transcribe and the plugin declines it. `reddit.js` outranks this plugin
// and declines a transcribe intent.

const LISTING_HOST = "https://www.reddit.com";

/// The headers Luna's own download engine sends the Reddit CDN.
const CDN_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15",
    Referer: "https://www.reddit.com/",
};

async function getJSON(request) {
    try {
        const response = await luna.fetch(request);
        if (!response.ok || typeof response.text !== "string") { return null; }
        return JSON.parse(response.text);
    } catch (error) {
        return null;
    }
}

function segments(parsed) {
    return String(parsed.pathname || "").split("/").filter(function (part) {
        return part.length > 0;
    });
}

/// The base-36 post id of a Reddit POST permalink, or null.
function postID(parsed) {
    const parts = segments(parsed);
    if (parsed.hostname === "redd.it") { return parts[0] || null; }
    const first = parts[0];
    if (!first) { return null; }
    if (first === "comments") { return parts[1] || null; }
    if ((first === "r" || first === "user" || first === "u")
        && parts.length > 2 && parts[2] === "comments") {
        return parts[3] || null;
    }
    if (first === "gallery") { return parts[1] || null; }
    return null;
}

/// True for Reddit's own app-native share link, `/r/<name>/s/<token>`.
function isShareLink(parsed) {
    const parts = segments(parsed);
    return parts[0] === "r" && parts.length > 3 && !!parts[1]
        && parts[2] === "s" && !!parts[3];
}

async function resolveShareLink(url) {
    try {
        const response = await luna.fetch({
            url: url, redirect: "follow", userAgent: "safari",
        });
        const landing = luna.parseURL(response.url || url);
        return landing ? postID(landing) : null;
    } catch (error) {
        return null;
    }
}

/// The post to read: a crosspost carries no media of its own, so its parent is
/// the source.
function sourcePost(listing) {
    if (!Array.isArray(listing) || !listing[0]) { return null; }
    const children = ((listing[0].data || {}).children) || [];
    const post = (children[0] || {}).data;
    if (!post) { return null; }
    const parents = post.crosspost_parent_list;
    if (Array.isArray(parents) && parents[0]) { return parents[0]; }
    return post;
}

/// The audio track's sibling URL, `audio` in the video file's directory.
function audioURL(videoURL) {
    const parsed = luna.parseURL(videoURL);
    if (!parsed) { return null; }
    const parts = segments(parsed);
    if (parts.length === 0) { return null; }
    parts[parts.length - 1] = "audio";
    return parsed.protocol + "//" + parsed.host + "/" + parts.join("/");
}

// MARK: - Text

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

/// `selftext_html` is the post body as HTML, escaped once more inside the JSON
/// string; one decode returns the markup.
function bodyHTML(post) {
    if (typeof post.selftext_html !== "string") { return ""; }
    const html = decodeEntities(post.selftext_html).trim();
    return html.length > 0 ? html : "";
}

luna.register({
    classify({ url }) {
        const parsed = luna.parseURL(url);
        if (!parsed) { return false; }
        const id = postID(parsed);
        if (id) { return { kind: "article", itemId: id }; }
        return isShareLink(parsed) ? { kind: "article" } : false;
    },

    async ingest({ url, claim }) {
        let id = claim && claim.itemId;
        if (!id) { id = await resolveShareLink(url); }
        if (!id) { return null; }

        const listing = await getJSON({
            url: LISTING_HOST + "/comments/" + id + ".json",
            headers: { Accept: "application/json" },
        });
        const post = sourcePost(listing);
        if (!post) { return null; }
        const video = ((post.secure_media || {}).reddit_video)
            || ((post.media || {}).reddit_video);
        if (!video || typeof video.fallback_url !== "string") { return null; }
        if (video.has_audio !== true) { return null; }
        const audio = audioURL(video.fallback_url);
        if (!audio) { return null; }

        const title = (typeof post.title === "string" && post.title.trim().length > 0)
            ? post.title.trim().slice(0, 300)
            : "Reddit " + id;
        const model = {
            kind: "article",
            title: title,
            transcription: { url: audio, type: "audio", headers: CDN_HEADERS },
        };
        const body = bodyHTML(post);
        if (body.length > 0) { model.html = body; }
        if (typeof post.author === "string" && post.author.length > 0) {
            model.author = "u/" + post.author;
        }
        return model;
    },
});
