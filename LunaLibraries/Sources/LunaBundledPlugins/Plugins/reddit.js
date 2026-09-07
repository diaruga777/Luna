/* luna-plugin
{
  "id": "app.luna.reddit",
  "name": "Reddit",
  "version": "1.0.0",
  "api": 1,
  "description": "Resolves a Reddit post's hosted video, with its separate audio track.",
  "produces": ["media"],
  "match": { "hosts": ["reddit.com", "*.reddit.com", "redd.it", "*.redd.it"] },
  "priority": 100,
  "capabilities": ["fetch"]
}
*/

// Reddit's public listing endpoint (`/comments/<id>.json`) answers for every
// permalink shape, so the plugin reconstructs one URL from the post id rather
// than rewriting the shared link.
//
// A Reddit-hosted video WITH sound is two DASH files: there is no muxed URL to
// download. The audio companion rides the asset as `audioURL`, derived from the
// video URL's sibling `audio` path — the name Reddit's own `DASHPlaylist.mpd`
// gives it — and `dashManifestURL` carries the manifest the downloader consults
// when that derivation misses.

const LISTING_HOST = "https://www.reddit.com";

async function getJSON(request) {
    try {
        const response = await luna.fetch(request);
        if (!response.ok || typeof response.text !== "string") { return null; }
        return JSON.parse(response.text);
    } catch (error) {
        return null;
    }
}

/// The path segments after the leading slash, empty ones dropped.
function segments(parsed) {
    return String(parsed.pathname || "").split("/").filter(function (part) {
        return part.length > 0;
    });
}

/// The base-36 post id of a Reddit POST permalink, or null.
///
/// Matching is structural: a subreddit named "comments" is a feed, and
/// `/user/<name>/comments/` with no id is a comment history. Neither is a post.
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

/// True for Reddit's own app-native share link, `/r/<name>/s/<token>`. The
/// token carries no post id; only a live redirect resolves it.
function isShareLink(parsed) {
    const parts = segments(parsed);
    return parts[0] === "r" && parts.length > 3 && !!parts[1]
        && parts[2] === "s" && !!parts[3];
}

/// The post id the share link redirects to.
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

/// The audio track's sibling URL. Reddit serves it at `audio` in the same
/// directory as every resolution's video file.
function audioURL(videoURL) {
    const parsed = luna.parseURL(videoURL);
    if (!parsed) { return null; }
    const parts = segments(parsed);
    if (parts.length === 0) { return null; }
    parts[parts.length - 1] = "audio";
    return parsed.protocol + "//" + parsed.host + "/" + parts.join("/");
}

/// `DASH_1080.mp4` names the leg's resolution, which is what matches a
/// re-resolved asset back to the job that was downloading it.
function quality(videoURL) {
    const match = /DASH_(\d{3,4})\b/.exec(String(videoURL));
    return match ? match[1] + "p" : null;
}

luna.register({
    classify({ url, intent }) {
        // A transcribe intent belongs to the transcript plugin, which sits
        // below this one in the walk.
        if (intent === "transcribe") { return false; }
        const parsed = luna.parseURL(url);
        if (!parsed) { return false; }
        const id = postID(parsed);
        if (id) { return { kind: "media", itemId: id }; }
        return isShareLink(parsed) ? { kind: "media" } : false;
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

        const asset = { url: video.fallback_url, type: "video" };
        const resolution = quality(video.fallback_url);
        if (resolution) { asset.quality = resolution; }
        // A thumbnail Reddit could not produce is the word "self" or "default",
        // not a URL. Only an http(s) one is worth carrying.
        if (typeof post.thumbnail === "string" && /^https?:\/\//.test(post.thumbnail)) {
            asset.thumbnailURL = post.thumbnail;
        }
        if (video.has_audio === true) {
            const audio = audioURL(video.fallback_url);
            if (audio) { asset.audioURL = audio; }
            if (typeof video.dash_url === "string") {
                asset.dashManifestURL = video.dash_url;
            }
        }
        return { kind: "media", platform: "reddit", itemId: id, assets: [asset] };
    },
});
