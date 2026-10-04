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

/// <reference path="../../../tools/plugin-sim/luna-plugin.d.ts" />

luna.register({
    classify({ url, intent }) {
        if (intent === "transcribe") return false;
        const id = luna.parseURL(url)?.pathname.match(/^\/clip\/([A-Za-z0-9_-]+)/)?.[1];
        return id ? { kind: "media", itemId: id } : false;
    },

    async ingest({ url, page, claim }) {
        const doc = page?.html ? luna.html.parse(page.html, page.url) : await luna.fetch.doc(url);
        // absoluteURL uses the fetched page's final URL, including redirects.
        const video = doc.querySelector('meta[property="og:video"]')?.absoluteURL("content");
        if (!video) return null;
        return {
            kind: "media",
            title: doc.querySelector('meta[property="og:title"]')?.getAttribute("content") || doc.title,
            itemId: claim.itemId,
            assets: [{ url: video, type: "video" }],
        };
    },
});
