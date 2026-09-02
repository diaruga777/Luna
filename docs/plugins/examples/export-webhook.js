/* luna-plugin
{
  "id": "docs.example.export-webhook",
  "name": "Webhook (example)",
  "version": "1.0.0",
  "api": 1,
  "description": "Posts an article's Markdown to a URL you configure.",
  "capabilities": ["fetch", "settings"],
  "export": {
    "kinds": ["article"],
    "input": "markdown",
    "title": "Send to Webhook",
    "symbol": "arrow.up.right.square",
    "requiresSettings": ["webhookUrl"]
  },
  "settings": [
    {
      "key": "webhookUrl",
      "type": "url",
      "label": "Webhook URL",
      "placeholder": "https://example.com/hook",
      "help": "Luna POSTs the article's Markdown here as the request body.",
      "required": true
    }
  ]
}
*/

// An export plugin needs no `produces`/`classify`/`ingest` — those are the
// ingest hooks. It needs only `export`, which the manifest's own `export`
// declaration requires `luna.register` to provide.
//
// This plugin delivers the article itself (a POST), so its `export` hook
// answers `null`: the share sheet has nothing left to show. Returning
// `{ text }`/`{ file }`/`{ url }` instead would hand the same content to the
// share sheet — see `kindle.js` for a plugin that emails a file, and
// `xteink.js` for one that reports `{ status }` as a queued destination.

luna.register({
    async export(input) {
        const webhookUrl = await luna.settings.get("webhookUrl");
        if (typeof webhookUrl !== "string" || webhookUrl.length === 0) {
            throw new luna.LunaError("hard", "no webhook URL is set");
        }
        if (typeof input.text !== "string") {
            throw new luna.LunaError("hard", "the article has no Markdown to send");
        }

        const response = await luna.fetch({
            url: webhookUrl,
            method: "POST",
            headers: { "Content-Type": "text/markdown" },
            body: input.text,
        });
        if (!response.ok) {
            // A plain throw (not `hard`) is a non-terminal failure: this
            // plugin declares no `destination`, so nothing retries it
            // automatically, but a user tapping the share row again is not
            // told the endpoint can never work.
            throw new Error("the webhook answered " + response.status);
        }
        return null;
    },
});
