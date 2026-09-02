/* luna-plugin
{
  "id": "app.luna.kindle",
  "name": "Kindle",
  "version": "1.0.0",
  "api": 1,
  "description": "Emails an article to your Kindle as an EPUB, through the account Luna sends from.",
  "priority": 100,
  "capabilities": ["mail", "settings"],
  "export": {
    "kinds": ["article"],
    "input": "epub",
    "title": "Send to Kindle",
    "symbol": "book.closed",
    "destination": true,
    "requiresSettings": ["kindleAddress"]
  },
  "settings": [
    {
      "key": "kindleAddress",
      "type": "email",
      "label": "Kindle Address",
      "placeholder": "you@kindle.com",
      "help": "Your Send-to-Kindle address. Add the account Luna sends from to Amazon's approved sender list, or the delivery is dropped.",
      "required": true
    },
    {
      "key": "senderNote",
      "type": "toggle",
      "label": "Include a note from Luna",
      "help": "Adds one line naming the article's source to the email body.",
      "default": true
    }
  ]
}
*/

// Amazon delivers by email: the EPUB goes to the Kindle address as an
// attachment, sent through the one account Luna is signed in to. Native builds
// the input EPUB (`input.file`) and the MIME, so this plugin never sees the
// article's bytes or the account's credentials.

const MIME = "application/epub+zip";

luna.register({
    async export(input) {
        const address = await luna.settings.get("kindleAddress");
        if (typeof address !== "string" || address.indexOf("@") < 0) {
            throw new luna.LunaError("hard", "no Kindle address is set");
        }
        if (!input.file) {
            throw new luna.LunaError("hard", "the article has no EPUB to send");
        }
        const note = await luna.settings.get("senderNote");
        const body = note === false
            ? ""
            : "Sent to Kindle by Luna.\n" + (input.url || "");
        await luna.mail.send({
            to: [address],
            subject: input.title,
            text: body,
            attachments: [{ file: input.file, name: input.file.name, mime: MIME }],
        });
        return { status: "sent" };
    },
});
