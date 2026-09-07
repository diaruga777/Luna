/* luna-plugin
{
  "id": "app.luna.x",
  "name": "X",
  "version": "1.0.0",
  "api": 1,
  "description": "Resolves an X post's photos and video through the keyless fxtwitter mirror.",
  "produces": ["media"],
  "match": { "hosts": ["x.com", "*.x.com", "twitter.com", "*.twitter.com"] },
  "priority": 100,
  "capabilities": ["fetch"]
}
*/

// X serves an unauthenticated client a JavaScript login shell, so the post is
// read from the keyless fxtwitter mirror instead of the page.
//
// The plugin DECLINES a long-form text post. Luna reads those with the reader
// (`XPostIngestProcessor`, LunaArticleIngest), and a media claim here would run
// before the Swift classifier and take the post away from it. The rule is the
// one `XPostExtractor` applies: the post the URL named wins as media when it
// carries a video or a GIF; otherwise an X Article, or an assembled body of at
// least `MINIMUM_BODY_LENGTH` characters, makes it a reader item.

const THREAD_ENDPOINT = "https://api.fxtwitter.com/2/thread/";
const STATUS_ENDPOINT = "https://api.fxtwitter.com/status/";

/// Assembled body length at which a text post becomes a reader article. It sits
/// far above X's 280-character ordinary-post cap, so no everyday post reaches
/// it. `XPostExtractor.minimumBodyTextLength` is the same number.
const MINIMUM_BODY_LENGTH = 600;

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

/// The posts to read: the unrolled thread when the v2 route answered, else
/// whichever single post the response carried.
function postsOf(payload) {
    if (Array.isArray(payload.thread) && payload.thread.length > 0) { return payload.thread; }
    if (payload.status) { return [payload.status]; }
    if (payload.tweet) { return [payload.tweet]; }
    return [];
}

/// The post the shared URL actually named. A thread unrolls from any member, so
/// this is not always the root, and it is what decides media against text.
function sharedPost(payload) {
    return payload.status || payload.tweet || postsOf(payload)[0] || null;
}

function mediaItems(post) {
    return (post && post.media && Array.isArray(post.media.all)) ? post.media.all : [];
}

function hasMotionMedia(post) {
    return mediaItems(post).some(function (item) {
        const type = String(item.type || "").toLowerCase();
        return type === "video" || type === "gif";
    });
}

/// The chain the reader would assemble: the root author's own posts, in order,
/// de-duplicated by id.
function authorThread(payload) {
    const posts = postsOf(payload);
    const root = payload.author || (posts[0] && posts[0].author);
    if (!root) { return posts; }
    const seen = {};
    return posts.filter(function (post) {
        const author = post.author;
        if (author) {
            const left = trimmed(author.id);
            const right = trimmed(root.id);
            if (left && right) {
                if (left !== right) { return false; }
            } else {
                const leftHandle = trimmed(author.screen_name);
                const rightHandle = trimmed(root.screen_name);
                if (leftHandle && rightHandle
                    && leftHandle.toLowerCase() !== rightHandle.toLowerCase()) {
                    return false;
                }
            }
        }
        const id = post.id;
        if (!id) { return true; }
        if (seen[id]) { return false; }
        seen[id] = true;
        return true;
    });
}

function trimmed(value) {
    if (typeof value !== "string") { return null; }
    const result = value.trim();
    return result.length > 0 ? result : null;
}

// MARK: - Thread counters

// A poster numbers a hand-written thread in the post body ("1/7", "🧵"), which
// is the only place that information lives. The reader strips those before
// measuring the body, so the plugin strips them too — otherwise the two would
// disagree about a post sitting near the threshold.

const LEADING_COUNTER = /^[\(\[]?\s*(\d{1,3})\s*\/\s*(\d{1,3}|[nNxX?])?\s*[\)\]]?\s*(?:[–—\-.:)]|\s)\s*/;
const LEADING_ORDINAL = /^(\d{1,3})()\s*[.)]\s+/;
const TRAILING_COUNTER = /[\s–—\-\(\[]+(\d{1,3})\s*\/\s*(\d{1,3}|[nNxX?])?\s*[\)\]]?\s*[.]?\s*$/;

/// One position marker at either end of `text`, or null.
function counterMatch(text) {
    const expressions = [LEADING_COUNTER, LEADING_ORDINAL, TRAILING_COUNTER];
    for (let i = 0; i < expressions.length; i++) {
        const match = expressions[i].exec(text);
        if (!match) { continue; }
        const numerator = parseInt(match[1], 10);
        if (isNaN(numerator)) { continue; }
        // Stripping must never consume the whole post.
        if (match[0].length >= text.length) { continue; }
        const denominator = match[2] === undefined ? "" : match[2];
        const total = parseInt(denominator, 10);
        if (!isNaN(total) && numerator > total) { continue; }
        return {
            index: match.index,
            length: match[0].length,
            numerator: numerator,
            isOpenEnded: denominator.length === 0 || isNaN(total),
        };
    }
    return null;
}

/// Removes each post's own position marker, but a CLOSED one ("3/5") only when
/// the chain shows a real scheme: an ordinary fraction reads the same way.
function strippingThreadCounters(texts) {
    const closed = [];
    texts.forEach(function (text) {
        const match = counterMatch(text.trim());
        if (match && !match.isOpenEnded) { closed.push(match.numerator); }
    });
    let ascending = closed.length >= 2;
    for (let i = 1; i < closed.length && ascending; i++) {
        if (!(closed[i - 1] < closed[i])) { ascending = false; }
    }
    return texts.map(function (text) {
        let result = text.trim();
        // A post can carry a marker at both ends.
        for (let pass = 0; pass < 2; pass++) {
            const match = counterMatch(result);
            if (!match) { break; }
            if (!match.isOpenEnded && !ascending) { break; }
            result = (result.slice(0, match.index) + " "
                + result.slice(match.index + match.length)).trim();
        }
        return stripThreadOrnaments(result);
    });
}

/// Thread furniture that carries no meaning once the chain is one document.
function stripThreadOrnaments(text) {
    let result = text;
    const patterns = [/^\s*🧵\s*/, /\s*🧵\s*$/, /\s*\/{1,2}(?:end|fin|END|FIN)\s*[.!]?\s*$/];
    for (let i = 0; i < patterns.length; i++) {
        const match = patterns[i].exec(result);
        if (!match || match[0].length >= result.length) { continue; }
        result = result.slice(0, match.index) + result.slice(match.index + match[0].length);
    }
    return result.trim();
}

// MARK: - The reader's own judgement

/// True when the reader would keep this payload as an article, so the plugin
/// must not claim it as media.
function readsAsArticle(payload) {
    const shared = sharedPost(payload);
    if (hasMotionMedia(shared)) { return false; }
    const posts = authorThread(payload);
    if (posts.length === 0) { return false; }

    // An X Article anywhere in the chain wins outright: it carries its own
    // title and body, so no length threshold applies.
    const hosted = posts.filter(function (post) {
        const blocks = post.article && post.article.content && post.article.content.blocks;
        return Array.isArray(blocks) && blocks.length > 0;
    });
    if (hosted.length > 0) { return true; }

    const texts = strippingThreadCounters(posts.map(function (post) {
        return typeof post.text === "string" ? post.text : "";
    }));
    let length = 0;
    let lines = 0;
    texts.forEach(function (text) {
        text.split(/\r\n|\r|\n/).forEach(function (line) {
            const block = line.trim();
            if (block.length === 0) { return; }
            lines += 1;
            length += block.length;
        });
    });
    // An image-only post assembles no text block at all, so it is not an
    // article whatever the threshold says.
    if (lines === 0) { return false; }
    return length >= MINIMUM_BODY_LENGTH;
}

// MARK: - Assets

/// The post's media in display order. X serves a "GIF" as an MP4, so anything
/// that is not a photo is a video.
function assetsOf(post) {
    const all = mediaItems(post);
    const assets = [];
    all.forEach(function (item) {
        if (typeof item.url !== "string" || item.url.length === 0) { return; }
        const type = String(item.type || "photo").toLowerCase();
        const asset = { url: item.url, type: type === "photo" ? "image" : "video" };
        if (typeof item.thumbnail_url === "string") {
            asset.thumbnailURL = item.thumbnail_url;
        }
        assets.push(asset);
    });
    if (assets.length > 0) { return assets; }

    const media = (post && post.media) || {};
    const fallback = [];
    (Array.isArray(media.videos) ? media.videos : []).forEach(function (item) {
        if (typeof item.url === "string") { fallback.push({ url: item.url, type: "video" }); }
    });
    (Array.isArray(media.photos) ? media.photos : []).forEach(function (item) {
        if (typeof item.url === "string") { fallback.push({ url: item.url, type: "image" }); }
    });
    return fallback;
}

luna.register({
    classify({ url, intent }) {
        // A transcribe intent belongs to the transcript plugin, which sits
        // below this one in the walk.
        if (intent === "transcribe") { return false; }
        const parsed = luna.parseURL(url);
        if (!parsed) { return false; }
        const id = statusID(parsed);
        return id ? { kind: "media", itemId: id } : false;
    },

    async ingest({ url, claim }) {
        const id = claim && claim.itemId;
        if (!id) { return null; }
        // The v2 thread route first: it unrolls a self-thread from any member,
        // so one call answers both the media question and the reader's.
        const payload = await getJSON(THREAD_ENDPOINT + id)
            || await getJSON(STATUS_ENDPOINT + id);
        if (!payload || postsOf(payload).length === 0) { return null; }
        if (readsAsArticle(payload)) { return null; }

        const assets = assetsOf(sharedPost(payload));
        if (assets.length === 0) { return null; }
        const model = { kind: "media", platform: "x", itemId: id, assets: assets };
        const title = trimmed((sharedPost(payload) || {}).text);
        if (title) { model.title = title.slice(0, 300); }
        return model;
    },
});
