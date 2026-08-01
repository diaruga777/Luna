# Double save (Action Button only)

Saving the exact same URL twice within 7 seconds through the Action Button
intents performs the action the user picked in **Settings → Shortcut & Safari →
Double Save**. Five choices, in picker order:

| Choice | What the second press does |
| --- | --- |
| **Nothing** (default) | No-op. |
| Send to Kindle | Emails the article's EPUB to the configured Kindle address. |
| Open PDF | Returns the article as a `.pdf` from the App Intent. |
| Open Markdown | Returns it as a `.md`. |
| Open Document | Returns it as a `.rtf`. |

Nothing is the default because a double save is easy to trigger by accident.

The setting exists only in the two apps that can act on it — **Luna** (central)
and **Luna Reader**, the two that link `LunaSend` — and is stored **per app**
(`DoubleSaveActionStore`, keyed by `LunaApp.storageIdentifier`), so each keeps
its own. Downloader and Price Tracker never show the section and never arm the
regime (`ActionButtonIntentSupport.doubleSaveSurface` is nil there).

No other save surface uses this regime. Share/action/Safari extensions, paste,
manual add, mail import, and every in-app save keep normal save semantics.

`SaveIntent` also detects a repeated screenshot by digest. A visually similar
screenshot inside the same seven-second window re-runs the previous save without
another model call, so it reaches the same decision.

## Flow

The Action Button intents pass a non-nil `doubleSaveActionSurface` through
`IntentIngestHelper` to `ReadingListIngestor.handleSavePress`.
`resolvedIntentAction` turns the stored `DoubleSaveAction` into a
`SavePressPolicy.IntentAction`, and **never returns nil** — an Action Button save
always stays in the 7 s intent regime rather than falling through to the legacy
12 s one. "Nothing", and a Kindle that isn't configured, both become
`.doNothing`.

A repeat inside `intentDoublePressWindow` (7 s) then becomes:

- `.sendToEreaders([kindle])`, retaining the 24-hour resend cooldown; or
- `.exportArticle(format:)` → `SavePressResult.exportRequested(item, format)`.

**The file is not built in the ingestor.** Serialization lives in `LunaSend`, an
article-kind module that the universal `LunaReadingList` / `LunaIntents` can't
link, so the press only *asks*: the outcome reaches the intent as
`IntentIngestHelper.ActionButtonSaveOutcome.exportRequested(item:format:)`, and
`ActionButtonIntentSupport.exportFile` builds it through the
`articleExporter` seam that `KindWiring+Luna` / `KindWiring+Reader` install
(`ArticleExportService().write(format, for:)`).

The returned file becomes the intent's **media** — `SaveResultEntity.media` /
`ProvideContextResultEntity.media` — replacing the media download for that run
(an article has none anyway). An export that can't be built returns no file
rather than throwing: a double save must never fail the save that preceded it.

Platform items (videos, posts, tracks) are excluded from both the Kindle and the
export actions — neither has an EPUB target nor stored article content.

The older 12-second in-app regime remains for a configured ereader destination
whose capture-source mode is `.doubleSave`; it also only sends to that ereader.
It is now unreachable from an Action Button save.

Legacy `DoubleSaveActionStore` values may remain in an existing App Group. The
retired `sendToFriend` action no longer decodes and reads back as `.nothing`;
the friend-prompt hand-off and preset-email storage survive unused, and pending
contact prompts are not consumed on foreground.

## Why RTF for "Open Document"

RTF is the open document format iOS Quick Look — what the Shortcuts "Quick Look"
action shows — renders natively. `.odt` it will not preview at all, and `.docx`
would need a full OOXML writer for no gain. `ArticleRTFBuilder` writes the markup
by hand rather than going through
`NSAttributedString.data(from:documentAttributes:)`, whose RTF path drops
`NSTextAttachment`s on iOS — that's what lets this format keep BOTH the
downloaded images (`{\pict}`) and live hyperlinks (`{\field HYPERLINK}`) in one
flat file. See article-export.md.

## Settings UI

`ShortcutSettingsScreen` (universal, `Luna/Settings/SettingsViewController.swift`)
draws the picker as a pull-down menu button — five options don't fit a segmented
control. It sits inside the same `#available(iOS 27.0, *)` gate as the rest of
the Action Button shortcut setup (app-intents.md): below iOS 27 there is no
shortcut section, so there is nothing for a double save to be a behavior of.
Picking "Send to Kindle" without a configured Kindle offers the setup it
needs through `DoubleSaveSettingsSupport.kindleSetupLauncher` (article-only
screens, installed by the same two `KindWiring` variants), and **keeps the
choice** either way: it goes live the moment Kindle is set up, and does nothing
until then.

## Tests

- `DoubleSavePolicyTests` — the seven-second boundary, the Kindle cooldown,
  platform-item exclusion for both Kindle and exports, each format round-tripping
  through the decision, and that `.doNothing` never falls back to the legacy
  ereader send.
- `DoubleSaveActionStoreTests` — the `.nothing` default, per-surface
  independence, the retired `sendToFriend` value reading back as the default, and
  the action → `ArticleExportFormat` mapping.
- `SavePressPolicyTests` — the older in-app ereader regime.
- `ArticleDocumentBuilderTests` — the RTF serializer.
