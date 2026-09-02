/* luna-plugin
{
  "id": "docs.example.minimal-media",
  "name": "ClipVault (example)",
  "version": "1.0.0",
  "api": 1,
  "description": "The smallest complete media plugin: matches one host, reads one og:video tag.",
  "produces": ["media"],
  "match": { "hosts": ["clipvault.example"] },
  "priority": 100,
  "capabilities": ["fetch", "html"]
}
*/

// A worked minimum, not a toy: `classify` decides from the URL alone (cheap,
// no network), and `ingest` fetches the page once and reads the single tag
// that names the video. Most real media plugins are this shape plus more
// tags to try — see `reddit.js` and `instagram.js` in
// `LunaLibraries/Sources/LunaBundledPlugins/Plugins/` for the two-legged
// (video + audio) and multi-stage versions of the same idea.

/// The clip id from a `/clip/<id>` path, or null for anything else on this host.
function clipID(url) {
    const parsed = luna.parseURL(url);
    const match = /^\/clip\/([A-Za-z0-9_-]+)/.exec(parsed.pathname || "");
    return match ? match[1] : null;
}

luna.register({
    classify({ url }) {
        const id = clipID(url);
        return id ? { kind: "media", itemId: id } : false;
    },

    async ingest({ url, claim }) {
        const response = await luna.fetch({ url });
        if (!response.ok) { return null; }

        const doc = luna.html.parse(response.text, url);
        const videoTag = doc.querySelector('meta[property="og:video"]');
        const videoURL = videoTag ? videoTag.getAttribute("content") : null;
        if (!videoURL) { return null; }

        const titleTag = doc.querySelector('meta[property="og:title"]');
        return {
            kind: "media",
            title: titleTag ? titleTag.getAttribute("content") : undefined,
            itemId: claim.itemId,
            assets: [{ url: videoURL, type: "video" }],
        };
    },
});
