/* luna-plugin
{
  "id": "docs.example.article",
  "name": "Article starter",
  "version": "1.0.0",
  "api": 1,
  "produces": ["article"],
  "match": { "hosts": ["journal.example"] },
  "capabilities": ["fetch", "html"]
}
*/
/// <reference path="../../../tools/plugin-sim/luna-plugin.d.ts" />

luna.register({
  classify({ url }) {
    return /^\/articles\/[^/]+/.test(luna.parseURL(url)?.pathname || "")
      ? { kind: "article" } : false;
  },

  async ingest({ url, page }) {
    // Reuse a supplied page. Otherwise retain the final URL after redirects.
    const source = page?.html ? { ok: true, text: page.html, url: page.url } : await luna.fetch(url);
    if (!source.ok) return null;
    const article = await luna.html.article(
      source.text, source.url);
    return article ? { kind: "article", ...article, baseURL: source.url } : null;
  },
});
