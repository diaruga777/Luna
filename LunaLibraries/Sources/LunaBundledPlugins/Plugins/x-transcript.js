/* luna-plugin
{
  "id": "app.luna.x.transcript",
  "name": "X transcript",
  "version": "1.0.0",
  "api": 1,
  "description": "Reads an X video post as an article by transcribing the video's audio.",
  "produces": ["article"],
  "match": { "hosts": ["x.com", "*.x.com", "twitter.com", "*.twitter.com"] },
  "priority": 90,
  "capabilities": ["fetch"]
}
*/

// The transcript twin of `x.js`. X publishes no captions and no separate
// audio file, so the source is the post's MP4 itself, which Luna downloads,
// transcribes and deletes. The post's own text leads the article. A post with
// no video is declined: the reader already handles long-form text posts, and
// a photo post has nothing to transcribe. `x.js` outranks this plugin and
// declines a transcribe intent.

const THREAD_ENDPOINT = "https://api.fxtwitter.com/2/thread/";
const STATUS_ENDPOINT = "https://api.fxtwitter.com/status/";

async function getJSON(url) {
    try {
        const response = await luna.fetch({
            url: url, headers: { Accept: "application/json" }, timeout: 10,
        });
        if (!response.ok || typeof response.text !== "string") { return null; }
        return JSON.parse(response.text);
    } catch (error) {
        return null;
    }
}

/// The numeric status id `/<user>/status/<id>` names, or null.
function statusID(parsed) {
    const parts = String(parsed.pathname || "").split("/").filter(function (part) {
        return part.length > 0;
    });
    for (let i = 0; i < parts.length; i++) {
        if (parts[i] !== "status" && parts[i] !== "statuses") { continue; }
        const id = parts[i + 1];
        return id && /^[0-9]+$/.test(id) ? id : null;
    }
    return null;
}

function postsOf(payload) {
    if (Array.isArray(payload.thread) && payload.thread.length > 0) { return payload.thread; }
    if (payload.status) { return [payload.status]; }
    if (payload.tweet) { return [payload.tweet]; }
    return [];
}

/// The post the shared URL actually named.
function sharedPost(payload) {
    return payload.status || payload.tweet || postsOf(payload)[0] || null;
}

function mediaItems(post) {
    return (post && post.media && Array.isArray(post.media.all)) ? post.media.all : [];
}

/// The post's video URL: the highest-bitrate MP4 variant when the item lists
/// variants, else the item's own URL. A GIF is an MP4 without speech and is
/// skipped.
function videoURL(post) {
    const items = mediaItems(post).filter(function (item) {
        return String(item.type || "").toLowerCase() === "video";
    });
    const fallbackVideos = (post && post.media && Array.isArray(post.media.videos))
        ? post.media.videos : [];
    const candidates = items.length > 0 ? items : fallbackVideos;
    for (let i = 0; i < candidates.length; i++) {
        const item = candidates[i];
        const variants = Array.isArray(item.variants) ? item.variants : [];
        let best = null;
        variants.forEach(function (variant) {
            if (typeof variant.url !== "string" || variant.url.length === 0) { return; }
            if (String(variant.content_type || "").indexOf("mp4") < 0
                && !/\.mp4(\?|$)/.test(variant.url)) { return; }
            const bitrate = typeof variant.bitrate === "number" ? variant.bitrate : 0;
            if (!best || bitrate > best.bitrate) { best = { url: variant.url, bitrate: bitrate }; }
        });
        if (best) { return best.url; }
        if (typeof item.url === "string" && item.url.length > 0) { return item.url; }
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

function titleOf(post, id) {
    const text = typeof post.text === "string" ? post.text.replace(/\s+/g, " ").trim() : "";
    if (text.length > 0) { return text.slice(0, 300); }
    const author = post.author || {};
    if (typeof author.name === "string" && author.name.length > 0) {
        return "Video by " + author.name;
    }
    return "X post " + id;
}

luna.register({
    classify({ url }) {
        const parsed = luna.parseURL(url);
        if (!parsed) { return false; }
        const id = statusID(parsed);
        return id ? { kind: "article", itemId: id } : false;
    },

    async ingest({ claim }) {
        const id = claim && claim.itemId;
        if (!id) { return null; }
        const payload = await getJSON(THREAD_ENDPOINT + id)
            || await getJSON(STATUS_ENDPOINT + id);
        if (!payload || postsOf(payload).length === 0) { return null; }
        const post = sharedPost(payload);
        if (!post) { return null; }
        const video = videoURL(post);
        if (!video) { return null; }

        const model = {
            kind: "article",
            title: titleOf(post, id),
            transcription: { url: video, type: "video" },
        };
        const text = textHTML(post.text);
        if (text.length > 0) { model.html = text; }
        const author = post.author || {};
        if (typeof author.name === "string" && author.name.length > 0) {
            model.author = author.name.slice(0, 300);
        } else if (typeof author.screen_name === "string" && author.screen_name.length > 0) {
            model.author = "@" + author.screen_name;
        }
        if (typeof post.lang === "string" && /^[a-z]{2,3}(-[A-Za-z0-9]+)?$/.test(post.lang)) {
            model.language = post.lang;
        }
        return model;
    },
});
