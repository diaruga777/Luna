# Composable app automation

Reader, Music, Vault, Keyboard and Writer expose user-owned content as App Entities and
small App Intents. The intent definitions live in each app target for metadata
extraction. Domain operations remain in services/stores: UIKit and intents use
the same implementations, permissions, file ownership and persistence rules.
An intent is an adapter to a domain action, rather than a second implementation.

For the searchable per-action inventory, open the
[automation atlas](../docs/automation-overview.html). It includes inputs, outputs,
entity properties, enums, notification contracts and internal events. Regenerate
it with `python3 scripts/build_automation_overview.py`.

Reader also exposes **Get Current Safari URL**: a no-input, non-opening action
that returns a typed URL from the same Safari extension tracking used by Reader.
It does not save or fetch content. It preserves query strings and fragments,
uses the existing 72-hour freshness window, and errors on missing, stale or
non-HTTP(S) values. This is the last extension-reported page, not a live active-tab
query. Reader now defines 15 discoverable actions including the two shared change
actions, plus two private Live Activity controls; its automatic shortcut provider
has eight entries. The video and shopping-price actions are available in the action
picker without adding automatic-shortcut entries.

Earlier October 30 Safari URL validation: the new action and its actual storage dependencies pass
an iOS 26 SDK type-check; all 11 Safari URL-store tests pass in an isolated macOS
test harness. The full app build and a device Shortcut invocation were not run
for this addition. Earlier build/metadata counts below describe their dated
verification runs.

## Entities and actions

| App | Entities | Actions |
| --- | --- | --- |
| Reader | Every saved item (articles, documents, products, social and media); existing readable-article entity | Find by text, original saved date, kind or stable ID; save URL; get text or text chunks; schedule trigger notifications; get downloaded video; get each tracked store’s last saved price; export device/Gemini TTS as M4A; batch read/unread, archive/unarchive, delete; existing capture and playback actions |
| Music | Songs, albums, artists, playlists (Apple Music and Vault); podcast shows/audio lists, episodes, stations | Find music; create/add to playlists; queue songs; existing playback controls; create audio lists; import audio; find episodes; get queue; enqueue/play-next/remove, listened/unplayed, download/remove download; follow/unfollow feed; create/update/delete station; export locally available podcast audio |
| Vault | Mirrored files and folders, including empty folders | Find by name/path/date/extension/file family; import/export file; create folder; delete; keep downloaded/unpin |
| Keyboard | Text/media shortcuts, dictionary words, supported preferences (including defaults) | Find/create/update/delete shortcuts; import/export images; find/add/remove dictionary words; get/set supported preferences |
| Writer | Sheets, notes and folders/projects | Find by stable ID/text/date; create/open sheets; get text; capture, find, update/delete notes; find/create folders; creation returns entities |
| All five | Data changes and a transient change-page value | Get changes with cursor and dismiss mutation notifications |

Entities expose properties for Shortcuts magic variables. Actions resolve IDs
against current storage instead of trusting stale snapshots. Queries do not
request Apple Music access or auto-pair a Mac. Vault export/delete require device
authentication. Destructive intents ask for confirmation. Existing premium and
voice credentials still apply. Private implementation objects such as caches,
credentials, transfer internals and search sidecars are not public entities.

IndexedEntity projections refresh at app launch, foreground and local mutations.
Reader keeps its existing article index alongside the broader saved-item index.
Music keeps its library-music index and adds podcast projections. Queries resolve
from authoritative stores even before a Spotlight refresh. Cross-process writes
are picked up when the owning app next runs/foregrounds; indexing is not a
background execution entitlement.

## Build Reader-to-Music in Shortcuts

On iOS 27, create a notification automation for Luna Reader matching the title
`Luna.reader.article.created`. Configure it to run automatically if desired.
Apple's [Shortcuts guide](https://support.apple.com/en-euro/guide/shortcuts/apdfbdbd7123/10.0/ios/27)
describes notification triggers. iOS 26 can run the same actions manually or with
another supported trigger, but does not provide that notification trigger.

1. Run Reader **Get Data Changes** with the token saved by the previous run.
   With no token, the action starts at the beginning of retained history.
2. Repeat through Changes. Keep `Item Type = article` and `Operation = created`.
3. Run Reader **Find Saved Items**, setting Item ID to the change's Item ID.
   If the save was deleted, decide whether to skip it or stop the shortcut.
4. Run Reader **Get Article Audio** on that saved item; choose device or Gemini
   voice. On iOS 27 builds, this uses LongRunningIntent and reports progress.
   iOS 26/stable-Xcode builds have the ordinary system intent time budget, so
   long exports can require a foreground workflow.
5. Run Music **Add Audio to Podcasts** with the file. Choose an Audio List, or
   leave it blank for Imported Audio. Set Title from the save, Add to Queue on,
   and Import Key to the save's stable ID. A retry with the same key and list
   returns the existing episode and deduplicates its queue entry.
6. Dismiss Reader **Change Notifications** for the processed Changes.
7. Save Next Token only after successfully processing the whole page. If Has
   More is true, request the next page and repeat. Store the final token in a
   file or another persistent Shortcuts storage action of your choice.

Create a named destination once using Music **Create Audio List**. These lists
are local shows in the existing podcast UI. Imported audio is copied into Music's
owned library, so expiring Shortcut files or deleting a Reader save do not break
playback. Imported lists/episodes are excluded from podcast cloud sync because
their audio is device-local. They never trigger RSS refreshes. Imported files are
not coupled to a Reader save's read state; a shortcut can explicitly mark the
source read when desired.

## Article chunks and scheduled triggers

**Get Article Text Chunks** takes a Saved Item and Maximum Characters (default
4,000, minimum 1). The item must be a ready article or document with saved text.
It returns an ordered list of strings, using the same block text and double
line-break separators as Get Saved Item Text. Each slice uses the furthest
sentence ending that fits the limit. If no sentence ending fits, it uses the
furthest word boundary; a word longer than the limit is split at whole Unicode
characters. Spaces, punctuation and line breaks count toward the limit and are
preserved exactly. Joining the list with an empty separator restores the full
input, with no gaps or duplicated text. Sentence boundaries use NaturalLanguage
tokenization; a final fragment without punctuation is still returned.

**Schedule Trigger Notification** schedules a one-time local notification under
Reader's identity and returns its notification ID. Delay is in seconds; 0 sends
immediately. Title is required. Optional fields are Subtitle, Body, User Info
(JSON object without null values), Notification ID, Thread ID, Category ID, Play
Sound, Badge and Delivery (Quiet, Standard or Time Sensitive). Quiet/silent is
the default; an empty Badge preserves the current badge and 0 clears it. Category
ID refers to a category the app already registers; it does not create actions.
Reader includes the Time Sensitive notification entitlement for that delivery
option; the user's system settings still control whether it can interrupt.

Use **Body** for data a Shortcuts notification automation needs to read, including
JSON. Custom `userInfo` is separate notification metadata and should not be
assumed accessible through Shortcuts' notification input. On iOS 27, configure
the notification automation for Luna Reader and match the title/subtitle/body.
This action schedules the notification; the user configures the automation.

If permission is undetermined, scheduling requests provisional alert/sound/badge
authorization and updates Reader's shared permission latch. Denied permission
throws with a Settings recovery message. Invalid parameters fail before asking
for permission. Scheduling is independent of Settings → Automations → Change
Notifications. IDs are scoped to `luna.trigger.` so these requests cannot replace
Reader's change/reminder notifications. Supplying the returned ID again replaces
that pending trigger. An empty ID generates a fresh UUID. Change-notification
dismissal does not remove scheduled triggers. Delivery follows system permission,
Focus and summary settings; the intent does not promise an exact firing time.

October 30 validation: Reader builds and 33 focused tests pass on the iOS 26.2
simulator with Xcode 27.1 beta. Tests cover lossless/greedy chunking, oversized
sentences/words, Unicode, saved-content retrieval/deletion, notification payloads,
permission outcomes, scheduling failures and existing saved-item/change actions.
Extracted App Intents metadata contains the chunk list output, all 11 notification
parameters, the delivery enum and eight automatic shortcuts. Reader's generated
simulator entitlements include Time Sensitive notifications. Physical-device Shortcuts
notification automations and actual delayed delivery were not exercised.

## Change contract

Settings → Automations → Change Notifications is off by default **per app**.
Writer now provides the same setting and change-page actions.
Keyboard's entry is under Preferences; Vault's is in its Mac/settings screen.
Opting in requests provisional notification permission when undetermined.
Notifications use passive interruption level, no sound/badge/body, stable titles,
and identifiers `luna.change.<event UUID>`. They include event ID, item ID, kind
and operation in userInfo, without titles, article text, credentials or file bytes.
Vault change item IDs are relative paths; resolve them with Find Vault Items → Path.

Title format: `Luna.<app>.<kind>.<operation>`; app is `reader`, `music`, `vault`,
`keyboard`, or `writer`; operation is `created`, `updated`, or `deleted`. Reader kinds are
`article` (including readable documents), `media`, `product`, and `link` for unextracted URLs. Music uses `song`, `playlist`, `show`,
`episode`, `station`, `queue`; Vault uses `file`/`folder`; Keyboard uses
`shortcut`, `word`, `preference`; Writer uses `document`, `note`, `group`. A shortcut should filter the returned changes,
not assume every event in a page matches the notification that woke it.

The journal stores the latest 10,000 events for each app, even with notifications
off. A page has up to 500 events and a generation-scoped opaque Next Token.
Reusing a token replays its events; each consumer owns its own cursor. Invalid,
foreign, future or expired tokens throw rather than silently skipping edits.
Dismissal removes only mutation notifications/outbox entries and never consumes
history or affects other notification categories. Notification delivery has a
durable outbox retried on launch/foreground, with stable IDs for retries.

Storage hooks record successful domain commits, including share-extension
writes, podcast feed merges, and incoming Vault index changes. Reader emits
`created` when ingestion first makes an item usable, rather than on a placeholder
that still has no article to export. Resume-position ticks, caches and incidental
bookkeeping do not produce a stream of notifications. Writes and their journal
append are separate commits; termination in that narrow interval can leave a
domain edit without an event. Consumers that need exhaustive recovery should
periodically reconcile a full item listing. The journal is not a transaction log.

The system owns notification delivery: permission, Focus, summaries, app limits,
and user settings can delay or suppress triggers. Provisional delivery is quiet;
foreground delegates suppress banners for mutation notifications. Apps cannot
force a user's system settings. A process cannot post a notification under a
sibling app's identity; changes to another app's data stay pending until its
owning app/extension runs. No app creates or executes a user's personal automation.

## Verification

Build all five schemes and inspect each app's
`Metadata.appintents/extract.actionsdata`: all actions must be present. Music's
AppShortcutsProvider has ten shortcuts, at Apple's maximum. New regression tests
cover journal paging/replay/reset/parallel writers, and actual audio-file copies,
queue deduplication and exclusion from cloud sync. No physical-device automation
or WebDriverAgent is used.

Verified for this implementation: all four app schemes build with Xcode 26.2;
Reader also builds with Xcode 27.0 and 27.1 beta, and exported metadata includes
LongRunning and ProgressReporting for Get Article Audio. App Intents metadata
contains Reader 10, Music 26, Vault 8 and Keyboard 11 discoverable actions.
Targeted iOS 26.2 simulator tests passed: 21 Reader journal/entity/store tests,
4 podcast import tests and 90 Keyboard tests (115 total, zero failures).
The user's notification automation still needs to be configured in Shortcuts;
that system trigger was not exercised by these unit tests.


## October 29 audit follow-up

The complete object/action/trigger inventory, rationale and reviewed regressions
are in [the recent churn audit](reviews/recent-churn-audit-2026-10-29.md).
Music now exposes Find Shows/Audio Lists, Find Stations and Play Episode/Station;
its existing automatic shortcut count remains ten. Writer exposes sheets, notes,
folders and the shared change actions. Keyboard preference values include valid
defaults on a fresh installation; arbitrary stored keys are not public settings.

Journal batches encode once per domain commit. Vault events describe visible
pre/post objects and include full-index removals. Writer uses connection-local
SQL triggers to collect committed mutations, coalescing creation/attachment and
ignoring timestamp-only writes, indexes, snapshots and reading marks. Reader URL
saves validate the post-ingest state and resolve deduplicated survivors.

Current metadata action counts are Reader 10, Music 30, Vault 8, Keyboard 11 and
Writer 12. Private download Live Activity controls retain their types but are no
longer discoverable as raw-job-ID Shortcut actions.


Audit verification: 312 Reader regression checks and 25 final capture/ingest
checks passed; Keyboard 91, Vault 9 and Writer's 24 focused service/settings
checks passed. The selected Music set executed 32 checks with one fixture skip
and no failures. Broader real-audio integration checks still failed or timed out
on the simulators; see the audit report for the full results and limits.


## October 30 action clarity audit

Reviewed every discoverable action in Reader, Music, Vault, Keyboard and Writer,
including the two shared change actions in each app. Each action has a description;
parameterized data actions include summaries that expose their optional filters.
The offline automation atlas was regenerated from the final definitions.

- **Reader — Get Saved Item Video:** takes a Saved Item and returns its downloaded
  video as a file with a readable filename and concrete file type. The service
  resolves the current save and its media by stable ID. It reuses the existing
  local/Photos export path; Photos still requires access. Missing saves, media
  that is not a downloaded video, and export failures throw actionable errors.
  This action does not start a download.
- **Reader — Get Shopping Item Prices:** takes a Saved Item with a price tracker
  and returns one Shopping Item Price per tracked store. Properties are Price,
  Currency Code, Store URL and Last Checked. These are saved observations, not a
  network refresh or a price comparison across converted currencies. Unknown
  prices and dates remain empty, rather than becoming zero or a made-up date.
- **Reader — Find Saved Items:** Item Type is a picker for Articles and Documents,
  Videos, Images and Social Posts, Shopping Items, or Web Links. These map to the
  existing `article`, `media`, `product`, `link` category codes. The labels describe
  the stored categories without guessing an exact media format before download.
  Item ID continues to override all filters, as described in the action.
- **Vault — Find Vault Items and Get Vault File:** File Extension accepts one
  extension with or without a leading dot, ignoring case and surrounding spaces.
  File Type offers Video, Audio, Image, PDF, Text and Archive. Matching uses filename
  extensions and system type conformance, with common additional media formats;
  it does not inspect file bytes. Both filters together require both to match.
  File filters exclude folders. Get Vault File still accepts a selected item;
  when omitted, it exports the newest modified matching file, with path as the
  tie-breaker. Selected items must also satisfy supplied filters. Export retains
  authentication and the existing Mac download path. No match throws an error.
- **Music:** Music Type replaces the raw string filter with Songs, Albums, Artists
  and Playlists. Playback names describe their effect, including podcast episodes.
  Descriptions explain playlist sources, feed URLs, audio lists, station filters,
  downloaded-only file export and import keys. Duration properties state seconds.
- **Keyboard:** preference entities display readable names and expose Accepted
  Values while retaining stable keys. Preference search accepts names or keys.
  Language Code gives examples, dictionary inclusion is Add to Dictionary, and
  shortcut keywords and replacement behavior have explicit guidance.
- **Writer:** Create Sheet, Open Sheet and Sheet parameters use consistent terms.
  Searches identify Sheet ID, Note ID or Folder ID and explain ID precedence.
  Create Sheet’s summary includes Folder. Text export, updates and deletion have
  descriptions of their actual effects.
- **Shared:** token input describes exactly where to obtain it and how an empty
  token behaves. Maximum Changes states the range. The entity’s sequence is an
  `Int` projection of the journal’s `Int64`, since the current SDK does not accept
  `Int64` as an App Entity property; persisted journal values are unchanged.

Intent identifiers and parameter identifiers are retained for existing actions.
The Reader and Music `kind` parameters now use App Enums with the existing category
raw values. Existing shortcuts that supplied arbitrary text should choose a valid
picker value when edited. Other fixed-choice inputs already used enums or entities;
free-text fields now explain their expected content instead of becoming enums
without a useful reason.


Validation for this audit: Xcode 27.1 beta / iOS 26.2 simulator builds succeeded
for all five apps. Focused simulator checks passed: Reader 25, Vault 4, Keyboard 1,
Writer 13 (43 total, zero failures). Exported metadata contains 13 Reader, 30 Music,
8 Vault, 11 Keyboard and 12 Writer discoverable actions. All have descriptions
and parameter titles. Reader and Music type filters export enum metadata; both
Vault actions export the extension input and six-choice File Type picker. The
video and shopping-price return types and optional missing-price fields are
present. The existing action identifiers and the automatic-shortcut counts are
preserved. This verifies compilation, metadata and focused domain behavior;
physical-device Shortcuts, Photos permission prompts and live Mac exports were
not exercised. Reusing the multi-app build folder caused a Keyboard linking
failure; a fresh Keyboard build folder passed without source or link changes.
