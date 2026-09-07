/* luna-plugin
{
  "id": "app.luna.tiktok",
  "name": "TikTok",
  "version": "1.0.0",
  "api": 1,
  "description": "Resolves a TikTok video or photo carousel from the watch page's own JSON.",
  "produces": ["media"],
  "match": { "hosts": ["tiktok.com", "*.tiktok.com"] },
  "priority": 100,
  "capabilities": ["fetch", "html"]
}
*/

// The watch page carries the item in one of two scripts, and BOTH wrap the same
// `itemStruct` — only the route in differs.
//
//   * The app shell puts it in `__UNIVERSAL_DATA_FOR_REHYDRATION__` under
//     `__DEFAULT_SCOPE__`.
//   * The logged-out "reflow" page — what a background fetch actually gets —
//     puts it in a separate `api-data` script, whose `__DEFAULT_SCOPE__` holds
//     reflow and ui-strategy keys and no video at all.
//
// The rehydration route is tried first, so the app-shell variant is not
// shadowed by a stale `api-data`.

const REHYDRATION_SCRIPT_ID = "__UNIVERSAL_DATA_FOR_REHYDRATION__";
const REHYDRATION_KEYS = ["webapp.video-detail", "webapp.reflow.video.detail"];

async function getHTML(url) {
    try {
        const response = await luna.fetch({
            url: url,
            userAgent: "safari",
            headers: { Accept: "text/html,application/xhtml+xml" },
        });
        if (!response.ok || typeof response.text !== "string") { return null; }
        return response.text;
    } catch (error) {
        return null;
    }
}

/// The parsed body of the `<script>` whose id attribute is exactly `id`.
///
/// The id is read off the element, so a script URL that merely mentions the
/// same word cannot be mistaken for the payload.
function scriptJSON(document, id) {
    const scripts = document.querySelectorAll("script");
    for (let i = 0; i < scripts.length; i++) {
        if (scripts[i].getAttribute("id") !== id) { continue; }
        try {
            return JSON.parse(scripts[i].innerHTML);
        } catch (error) {
            return null;
        }
    }
    return null;
}

function itemStruct(document) {
    const rehydration = scriptJSON(document, REHYDRATION_SCRIPT_ID);
    const scope = rehydration && rehydration.__DEFAULT_SCOPE__;
    if (scope) {
        for (let i = 0; i < REHYDRATION_KEYS.length; i++) {
            const detail = scope[REHYDRATION_KEYS[i]];
            const item = detail && detail.itemInfo && detail.itemInfo.itemStruct;
            if (item) { return item; }
        }
    }
    const apiData = scriptJSON(document, "api-data");
    const videoDetail = apiData && apiData.videoDetail;
    const item = videoDetail && videoDetail.itemInfo && videoDetail.itemInfo.itemStruct;
    return item || null;
}

/// TikTok signs a play address with an expiry; the engine re-runs this plugin
/// once it passes rather than downloading a refusal.
function expirySeconds(rawURL) {
    const parsed = luna.parseURL(rawURL);
    if (!parsed) { return null; }
    const value = parseInt(parsed.searchParams.get("expire") || "", 10);
    return isNaN(value) || value <= 0 ? null : value;
}

function carouselAssets(item) {
    const images = (item.imagePost && Array.isArray(item.imagePost.images))
        ? item.imagePost.images : [];
    const assets = [];
    images.forEach(function (image) {
        const list = image.imageURL && image.imageURL.urlList;
        const first = Array.isArray(list) ? list[0] : null;
        if (typeof first === "string" && first.length > 0) {
            assets.push({ url: first, type: "image" });
        }
    });
    return assets;
}

/// The watermark-free `playAddr`, else the watermarked `downloadAddr`.
function videoAsset(item) {
    const video = item.video;
    if (!video) { return null; }
    const address = (typeof video.playAddr === "string" && video.playAddr.length > 0)
        ? video.playAddr
        : video.downloadAddr;
    if (typeof address !== "string" || address.length === 0) { return null; }
    const asset = { url: address, type: "video" };
    const covers = ["cover", "originCover", "dynamicCover"];
    for (let i = 0; i < covers.length; i++) {
        if (typeof video[covers[i]] === "string" && video[covers[i]].length > 0) {
            asset.thumbnailURL = video[covers[i]];
            break;
        }
    }
    return asset;
}

luna.register({
    classify({ url, intent }) {
        // A transcribe intent belongs to the transcript plugin, which sits
        // below this one in the walk.
        if (intent === "transcribe") { return false; }
        const parsed = luna.parseURL(url);
        if (!parsed) { return false; }
        const parts = String(parsed.pathname || "").split("/").filter(function (part) {
            return part.length > 0;
        });
        for (let i = 0; i < parts.length; i++) {
            if (parts[i] === "video" && /^[0-9]+$/.test(parts[i + 1] || "")) {
                return { kind: "media", itemId: parts[i + 1] };
            }
        }
        // A short `vm.`/`vt.`/`/t/` link carries no id; the page it lands on
        // holds the item.
        return { kind: "media" };
    },

    async ingest({ url, page }) {
        // A snapshot the surface already read saves a round trip, but it may be
        // a variant with no item in it, so a miss still asks the page itself.
        let item = null;
        if (page && typeof page.html === "string") {
            item = itemStruct(luna.html.parse(page.html, url));
        }
        if (!item) {
            const html = await getHTML(url);
            if (!html) { return null; }
            item = itemStruct(luna.html.parse(html, url));
        }
        if (!item) { return null; }

        const assets = carouselAssets(item);
        if (assets.length === 0) {
            const video = videoAsset(item);
            if (!video) { return null; }
            assets.push(video);
        }
        const model = { kind: "media", platform: "tiktok", assets: assets };
        if (typeof item.id === "string" && item.id.length > 0) { model.itemId = item.id; }
        if (typeof item.desc === "string" && item.desc.length > 0) {
            model.title = item.desc.slice(0, 300);
        }
        const expiry = expirySeconds(assets[0].url);
        if (expiry) { model.expiresAt = expiry; }
        return model;
    },
});
