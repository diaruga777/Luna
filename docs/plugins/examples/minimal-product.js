/* luna-plugin
{
  "id": "docs.example.product",
  "name": "Product starter",
  "version": "1.0.0",
  "api": 1,
  "produces": ["product"],
  "match": { "hosts": ["shop.example"] },
  "capabilities": ["fetch", "html"]
}
*/
/// <reference path="../../../tools/plugin-sim/luna-plugin.d.ts" />

luna.register({
  classify({ url }) {
    return /^\/products\/[^/]+/.test(luna.parseURL(url)?.pathname || "")
      ? { kind: "product" } : false;
  },

  async ingest({ url, page }) {
    const doc = page?.html ? luna.html.parse(page.html, page.url) : await luna.fetch.doc(url);
    const product = luna.html.jsonLD(doc).find((item) =>
      [item["@type"]].flat().includes("Product"));
    const offer = Array.isArray(product?.offers) ? product.offers[0] : product?.offers;
    const amount = String(offer?.price ?? "");
    if (typeof product?.name !== "string" || !product.name.trim()
        || !/^\d+(?:\.\d+)?$/.test(amount)
        || !/^[A-Z]{3}$/.test(offer?.priceCurrency || "")) return null;
    return {
      kind: "product",
      name: product.name.trim(),
      price: { amount, currency: offer.priceCurrency },
      imageURL: doc.querySelector('meta[property="og:image"]')?.absoluteURL("content") || undefined,
    };
  },
});
