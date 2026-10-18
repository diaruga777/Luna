# The Luna file

A Luna file is how a chat reply comes back into Luna. The user asks ChatGPT or
Claude to recover a page or to write a plugin, the model answers with one binary
attachment, and the user taps it. The system registers it as custom data, so
Open In, Files and the share sheet can send it to Luna without advertising a
generic text preview.

## The shape

New attachments are a binary container:

- Bytes 0–8: `89 4c 55 4e 41 0d 0a 1a 0a` (Luna signature).
- Byte 9: `01` (container version 1, separate from the header's API version).
- Remaining bytes: exactly one RFC 1950 zlib stream of the complete UTF-8 source.

Python generation: `bytes.fromhex('894c554e410d0a1a0a01') +
zlib.compress(source.encode('utf-8'))`, written in binary mode and delivered as
`application/octet-stream`. Prompts for recovery, plugin creation and correction
all require this attachment and explicitly reject plaintext/code-block fallback.
If a provider cannot create binary attachments, it must say so. This prevents
ordinary text previews; it is compression, not encryption or access control.

`LunaFileReader` decodes the envelope in Open In, share/action, and manual plugin
imports. It caps compressed bytes at zlib's `compressBound(1 MiB)` plus 10 bytes,
caps decoded source at 1 MiB, and rejects truncation, corrupt checksums, trailing
bytes and unknown versions. Legacy UTF-8 attachments and pasted source remain
readable for compatibility. The plugin simulator reads both formats too.

In the decoded source, the first non-whitespace token is a block comment whose
first line, trimmed, is the **marker**. The rest of the comment is one JSON
object. Everything after the comment's closing `*/` is the body.

| Marker | Body | Meaning |
| --- | --- | --- |
| `luna-plugin` | JavaScript | a plugin draft (`docs/plugins/README.md` §1) |
| `luna-recovery` | one JSON object | a recovered save |

Anything else is not a Luna file: no comment, a marker that is a near miss
(`luna-plugin-evil`), or an unparseable header. Only the **first** `*/` closes
the header, so a body may hold one of its own. The size cap is 1,024 KB
(`LunaFileLimits.maxSourceKB`) — Safari's message channel caps a served plugin
source at 1.5 MB, so a larger file could never run everywhere it must.

`LunaFileHeader.parse` (LunaModels) reads this shape, once, for both readers.
`PluginManifestParser.extractHeader` calls it and translates a failure into the
plugin author's vocabulary; `LunaRecoveryFile.parse` reads the recovery half.
Line numbers count from the first line of the decoded SOURCE, as shown in
Luna's source viewer.

## A recovery file

```
/* luna-recovery
{ "api": 1, "url": "https://example.com/the-page", "kind": "article" }
*/
{
  "recipe": { "url": "https://example.com/the-page?output=amp",
              "headers": { "user-agent": "googlebot" },
              "javascript": "return document.querySelector('article').outerHTML" },
  "content": { "kind": "article", "title": "…", "html": "<p>…</p>" }
}
```

Header: `api` must be 1, `url` is the page the user saved (absolute http or
https), `kind` is `article` / `media` / `product` and must equal the content's
kind, and `note` is optional free text (≤ 300 characters) kept for diagnostics.

`content` is required and is exactly a plugin `PluginModel` of that kind — the
same decoder and the same caps, so a title over 300 characters or an `ftp://`
asset is refused here for the same reason it is refused from a plugin.

`recipe` is optional: a replayable way to reach the page, so Luna can learn a
host rule instead of only adopting one answer. `url` is absolute http(s);
`headers` keeps `user-agent`, `referer` and `accept-language` and **drops**
everything else rather than failing — a model that adds `cookie` should lose
the header, not the recovery; `javascript` is at most 8 KiB and must return a
string; `returns` is `html` (the default), `json` or `mediaURL`. Whoever
replays the recipe validates its destination against its own rules.

## The types

Each app owns one file extension, and all four apps EXPORT all four
declarations — an exporter set that agrees is harmless, and it means each app
knows the family whether or not its siblings are installed. During migration,
update the installed sibling apps as well: an older sibling still exports the
previous text conformance and can keep that definition in the system registry.
Registration tests should run with matching app versions or on a fresh simulator;
never erase a user's simulator just to change this cache.

| UTI | Extension | Conforms to | App |
| --- | --- | --- | --- |
| `<prefix>.file` | `luna` | `public.data`, `public.content` | central Luna |
| `<prefix>.reader.file` | `lunar` | `<prefix>.file` | Luna Reader |
| `<prefix>.downloader.file` | `lunad` | `<prefix>.file` | Luna Downloader |
| `<prefix>.pricetracker.file` | `lunas` | `<prefix>.file` | Luna Price Tracker |

The three sibling types conform to the central one, so central Luna claims ONE
document type and still opens all four extensions. `CFBundleDocumentTypes` has
a single entry whose `LSItemContentTypes` is `$(LUNA_DOC_UTI)`, set per app
target in `project.pbxproj` beside `$(LUNA_URL_SCHEME)`;
`scripts/add_luna_app.rb` sets both for a new app. A FIFTH app also needs its
declaration added to the exported list in `Luna/Info.plist` by hand — that list
is four literal entries, not a loop.

`LSSupportsOpeningDocumentsInPlace` is false: Luna reads the inbox copy and
deletes it. `LunaApp.fileExtension` / `.acceptedFileExtensions` /
`.fileTypeIdentifier` / `.acceptedFileTypeIdentifiers` are the in-code mirror,
built on `AppConfig.productBundlePrefix`. `LunaFileTypeTests` reads the BUILT
host's `Info.plist` and the system type database, which is the only place the
xcconfig → Info.plist chain can be observed.

## Intake

`LunaFileIntake.classify(text:)` answers with the file's kind, the error that
stopped a recognized file, or **nil when the text is not a Luna file at all**.
It is pure, so every surface answers the same way. What HAPPENS next is the
surface's own business, through two seams:

```swift
@MainActor public protocol LunaRecoveryFileHandling: AnyObject {
    func handleRecovery(_ file: LunaRecoveryFile, sourceURL: URL?)
}

@MainActor public protocol LunaPluginFileHandling: AnyObject {
    func handlePlugin(source: String, headerJSON: String)
}
```

They are separate because different tiers own them: every app recovers a save,
only central Luna reviews a plugin draft. Every composition root installs both
— the twelve `KindWiring+*`, `ShareEntry+*` and `ActionEntry+*` files — so a
Luna file reaching any surface is always accounted for.
`KindCompositionRootTests` fails the build on a root that writes neither, and
on anything else that writes either one.

| Route | Where | What happens |
| --- | --- | --- |
| Open In, Files, "Open in Luna" | `SceneDelegate.route`'s `url.isFileURL` branch | security-scoped read (≤ 1 MB), delete the inbox copy, classify, dispatch |
| Share or action sheet, a file | `ShareAttachmentRouter` → `.lunaFile`, `ShareViewController.handleLunaFile` | read the provider's copy, classify, dispatch |
| Share sheet, plain text | `ShareViewController.handleText`, before link extraction | the fallback for a provider that can only show the file as a code block |
| A `.js` or `.luna` plugin file | Settings → Plugins → + | the existing manual import |

The router matches a Luna file FIRST and **by identifier**, not by `UTType`
conformance: a `UTType` resolves only while an app that exports it is installed.
The custom type conforms to data and content, never text. A file-URL-only share
checks the family's extensions (case-insensitively) before importing an ordinary
document. `handleDocument` retains its legacy source check for a host advertising
an old attachment as plain text. `LunaFileTypeTests` checks the built declarations
and verifies all four system types conform to data and do not conform to text.

A recovery file whose kind the app does not handle meets the ordinary surface
gate (`SurfaceSupport`) and shows `UnsupportedSaveCardViewController`. A plugin
draft outside central Luna shows the same card, saying "Plugins run in Luna." —
the sibling apps link none of the plugin platform.

## The deep link

`<scheme>://llm?item=<uuid>` is the extension's hand-off falling back to the
app: an extension may only ask its host to open a URL and the host may refuse,
so the extension opens this instead and the app opens the provider from a
process that is always allowed to. A Luna file never travels in a deep link.
