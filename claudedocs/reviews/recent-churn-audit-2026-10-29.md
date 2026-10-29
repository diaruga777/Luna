# Recent churn and automation audit — 29 October 2026

Reviewed the 24–29 October changes through `30c5be33d`, with detailed review of
29 October automation/narration changes and their interactions with the Reader
consolidation, Music readouts, lazy reader construction, and Vault video work.
This is a bounded code/history audit, not a claim that all 4,000+ Reader tests or
every device/network combination has been exercised.

## Findings and changes

| Area | Intended behavior | Finding and resolution |
| --- | --- | --- |
| Reader Save URL | Return the persisted save for the next shortcut action | Failed extraction was returned as success; wrapper deduplication could instead report a missing placeholder. Verify the post-ingest state and resolve the surviving save through the shared ingestor. Record the capture source as an app intent. |
| Capture app gate | Ignore screens inside the Luna family | Consolidation reduced `LunaApp.allCases` to shared-shell surfaces, dropping Music/Keyboard from capture exclusion. Recognize current companions and installed legacy names before URL/screenshot handling. |
| Nightly narration | Prepare recent unread articles, newest first | Eligibility accepted any ready save, including media/products with text, archived items and items awaiting archive. Restrict to active text saves; keep original saved-date ordering, the fourteen-day cutoff and fixed-PST window. |
| Automation identities | Deliver changes under the owning app | Reader's namespace-prefix match classified unlisted/retired apps and Writer as Reader. Resolve explicit companion apps and only Reader's known extension IDs. Unknown apps no longer fall back to Reader in shared intent adapters. |
| Journal performance | Record changes without delaying normal app use | Feed merges and multi-item saves re-encoded retained history for every item. Append a batch in one locked snapshot write. Change-entity resolution also reads once instead of paging and re-decoding the journal repeatedly. |
| Keyboard dictionary | Trigger on actual edits | Re-adding an existing word or deleting an absent word emitted changes. Use the committed SQLite change count. |
| Keyboard preferences | Configure supported settings through Shortcuts | A fresh install returned no preferences because only persisted overrides were projected. Project supported defaults and validate boolean/theme/language/style values. Unknown internal keys are excluded. |
| Keyboard media | Compose image shortcuts from files | File export existed without a corresponding input. Add an optional image to the existing Save Keyboard Shortcut action, using the existing owned-file copy/size/type checks. |
| Music progress | Notify for listened-state changes, not position bookkeeping | `nil` versus initial `listened = false` emitted an update on first progress creation. Compare normalized boolean values. |
| Music queries | Resolve local library snapshots without remote refresh | Entity and Find queries called reload with its default Mac refresh. Use `refreshVault: false`; no Apple Music authorization prompt is introduced. Preserve caller ID order when resolving music entities. |
| Music composition | Find an object, then act on it | Add Find Shows/Audio Lists and Find Stations, stable-ID lookup for library music, and Play Episode/Station actions. Allow an empty Vault playlist to be created explicitly. Existing action IDs and the ten automatic shortcuts remain. |
| Music test linkage | Run Reader-to-Music regression coverage | Tests imported Models/Storage/AppConfig/DesignSystem without linking them after Vault integration promoted those shared modules into separate frameworks. Add direct test dependencies to the modules already promoted by the app's graph. Update the stale root-menu assertion for the intentional Luna Reader row. |
| Vault changes | Reflect visible mirrored files/folders | Tombstones/invalid entries could produce events for nonexistent objects; resurrection was called updated, and full-index purges emitted no deletion. Diff the actual visible pre/post records, batch changes and record purged deletions. Unpinning a never-cached file is now a no-op. |
| Writer composition | Use sheets/notes/folders as shortcut values | Create Sheet had no output; notes/folders had no entities or Find actions. Add these adapters and text retrieval, note update/delete and folder creation. Add Note returns all created/routed notes while retaining its existing dialog. |
| Writer capture | Respect an explicitly chosen destination | A missing destination silently routed the note somewhere else; blank input reported an Inbox success without saving. Throw clear errors before writing. Open Sheet also rejects a missing ID. |
| Writer triggers | Offer the same opt-in change contract as other apps | Add the shared actions/settings and journal document/note/group commits using connection-local SQLite triggers. Rollbacks publish nothing; note creation plus attachment in one transaction is one created event. Ignore timestamps, embeddings, snapshots and reading marks. |
| Private controls | Keep Shortcuts focused on usable actions | Hide download Live Activity suspend/resume actions from discovery: their raw internal job IDs are not user-resolvable objects. Keep their types for existing widget buttons. |

The speech recovery/cache implementation, author-voice selection, lazy alternate
readers and the read/unread pull gesture were retained. No publisher-specific
logic was moved into Swift; no media plugin was added to app resources. No
physical device, WebDriverAgent, Mac signing, App Store submission or purchase
was involved.

## Objects, actions and triggers

An object is durable user content or a supported preference with a stable ID.
An action finds, creates, reads, changes or plays that object. A trigger reports
a meaningful committed change, letting the shortcut resolve its ID and decide
what to do. App lifecycle notifications, position ticks, cache jobs, secrets and
transport internals do not become additional public objects.

The selected set favors a few composable primitives. It preserves existing
intent/entity identifiers so installed shortcuts continue to resolve them.

### Reader

**Objects:** `SavedItemEntity` for every save; `ArticleEntity` remains for existing
Read Article shortcuts. Articles include imported readable documents; saved-item
kinds are `article`, `media`, `product`, or `link`, with state/read state exposed
separately. Media includes social/video/audio saves. Capture results are transient
transport values, not independent content objects.

**Actions (10):** Provide Context; Save; Read Article; Save URL; Find Saved Items
(text, stable ID, original saved date, kind, unread and archive filters); Get
Saved Item Text; Get Article Audio; Update Saved Items (read/unread,
archive/unarchive/delete); Get Data Changes; Dismiss Change Notifications.

**Automation notifications:** `Luna.reader.<article|media|product|link>.<created|updated|deleted>`.
Ingest placeholders do not emit created until usable. Text/read/archive changes
are meaningful; position ticks are not. Kind upgrades can emit created for the
new usable kind. Reader-to-Music shortcuts should filter article-created changes
and use stable import keys for idempotent retries.

**Other notifications:** incoming friend shares, price-drop alerts, weekly-save
proposals, Xteink Wi-Fi readiness, plugin-authorized notifications and optional
Premium happy-hour reminders. These are user alerts with their own settings and
payloads, not substitutes for the mutation journal. Scheduled nightly audio is
background preparation, not a notification-based automation trigger.

### Music

**Objects:** `LibraryMusicEntity` represents songs, albums, artists and playlists
with a kind discriminator and source-qualified ID; `PodcastShowEntity` represents
RSS shows and local audio lists; `PodcastEpisodeEntity`; `PodcastStationEntity`.
The queue is an ordered relationship returned as episodes, not another mutable
copy of an episode entity.

**Actions (30):** Find Library Music; Play Library Music; Search Music Library
(opens the UI); Resume Music; Pause If Playing; Seek; Play or Pause Music;
Next Song; Previous Song; Switch Music and Podcasts; Create Music Playlist;
Add Songs to Playlist; Add Songs to Music Queue; Resume Podcast Queue;
Find Podcast Shows and Audio Lists; Create Audio List; Add Audio to Podcasts;
Find Podcast Episodes; Get Podcast Queue; Update Podcast Episodes
(enqueue/play-next/remove, listened/unplayed, download/remove-download);
Follow Podcast Feed; Set Podcast Followed; Find Podcast Stations; Save Podcast
Station; Delete Podcast Station; Play Podcast Episode; Play Podcast Station;
Get Podcast Audio File; Get Data Changes; Dismiss Change Notifications.

**Automation notifications:**
`Luna.music.<song|playlist|show|episode|station|queue>.<created|updated|deleted>`.
Song events come from Vault catalog changes; playlist events cover Luna's own
playlist writes. System Music library edits made outside Luna are not a promised
journal stream. Podcast events cover committed metadata/listened state and queue
changes; normal playback position saves do not emit events. Queue item ID is
`podcasts`.

**Other notifications:** followed-show new-episode alerts, with Open, Add to Queue
and Play Next interactions; optional Premium happy-hour reminders. Keeping the
human new-episode alert separate from quiet automation events is deliberate.

### Vault

**Objects:** `VaultFileEntity` for files and folders, including empty directories.
Entity IDs include peer and folder identity; the journal's item ID is the
relative path and resolves through Find Vault Items → Path. The current
composable surface addresses the paired-Mac mirrored store.

**Actions (8):** Find Vault Items; Save File to Vault; Get Vault File; Create Vault
Folder; Delete Vault Items; Keep Vault File Downloaded; Get Data Changes;
Dismiss Change Notifications. Get/Delete require device authentication; deletion
also asks for confirmation.

**Automation notifications:**
`Luna.vault.<file|folder>.<created|updated|deleted>` for visible objects, including
full-index disappearance and tombstone resurrection. Cache access/eviction and
transfer progress stay out of the event stream. Unpairing/replacing a Mac changes
entity identity; consumers should reconcile their item listing after pairing.

**Other notifications:** optional Premium happy-hour reminders. Transfer progress
UI and connectivity callbacks are not automation notifications.

### Keyboard

**Objects:** `KeyboardShortcutEntity` for text/image/GIF shortcuts;
`KeyboardWordEntity` for language-qualified dictionary words;
`KeyboardPreferenceEntity` for supported settings, including defaults.

**Actions (11):** Find Keyboard Shortcuts; Save Keyboard Shortcut (create/update,
optional image input); Delete Keyboard Shortcuts; Get Keyboard Shortcut File;
Find Dictionary Words; Set Keyboard Dictionary Word; Delete Dictionary Words;
Get Keyboard Preferences; Set Keyboard Preference; Get Data Changes;
Dismiss Change Notifications.

**Automation notifications:**
`Luna.keyboard.<shortcut|word|preference>.<created|updated|deleted>` as applicable.
Preferences emit updated; real word insert/delete operations emit created/deleted.
Typing, prediction, recency and cosmetic keyboard state do not emit mutations.

**Other notifications:** optional Premium happy-hour reminders. Keyboard activation
is a system event, not an app-authored notification contract.

### Writer

**Objects:** `WriterDocumentEntity` (sheet), `WriterNoteEntity`, `WriterGroupEntity`
(folder, project, Inbox or Trash). Reading marks, revisions, FTS indexes and
snapshots remain data belonging to a sheet rather than separate mutable entities.

**Actions (12):** Add Note (returns all captured notes); New Sheet (returns the
sheet, optional destination folder); Open Sheet; Find Writer Sheets; Get Writer
Sheet Text; Find Writer Notes; Update Writer Note; Delete Writer Notes;
Find Writer Folders; Create Writer Folder; Get Data Changes;
Dismiss Change Notifications.

**Automation notifications:**
`Luna.writer.<document|note|group>.<created|updated|deleted>`.
Trash/restore are document updates because the sheet still exists; emptying Trash
emits deleted. Sheet text saves are updates; notes expose their owning sheet IDs.
The setting is off by default under Settings → Automations. SQLite TEMP triggers
are connection-local projections, so they do not migrate or alter the persistent
Writer schema. Derived data and timestamp-only updates do not produce events.

**Other notifications:** optional Premium happy-hour reminders.

### Shared values, compatibility and exclusions

All five apps expose `DataChangeEntity` and transient `DataChangePageEntity`.
Get Data Changes has an independent replayable cursor per shortcut consumer;
Dismiss Change Notifications never consumes that cursor/history. Mutation
notifications are opt-in, quiet, and contain IDs rather than user content.
Permission, Focus, system limits and owning-app execution still govern delivery.
A notification is a wake-up hint, not a guaranteed transaction log.

[Apple's WWDC26 Shortcuts overview](https://developer.apple.com/videos/play/wwdc2026/310/)
introduces notification automations for iOS 27. The same actions can be composed
with other system triggers on iOS 26. Luna never creates a personal automation
on the user's behalf. [Apple's EntityQuery documentation](https://developer.apple.com/documentation/appintents/entityquery)
describes ID-based resolution used by these adapters.

Reader's older article entity and capture intents are compatible projections,
not retired solely for being narrower than Saved Item. Music's Search action has
a different result (navigation) from Find (data). The batch dictionary delete
is useful beside scalar Set Word. Removing those would break useful workflows.
Only internal raw-job-ID controls were removed from discovery.

Do not add every feature as a new intent or invent public cache/credential,
playhead, transfer-session, notification-request or pairing-secret entities.
Do not duplicate OS playback/keyboard triggers with high-frequency notifications.
The retired Reader/Downloader/Price Tracker targets are not separate apps in this
inventory. Luna Mac is a companion service for Vault/Music with no independent
App Intents catalog. Orbit owns its own app/automation surface and is out of scope.

## Verification

All five iOS schemes built with Xcode 26.2. Extracted App Intents metadata
contains Reader 10, Music 30, Vault 8, Keyboard 11 and Writer 12 actions. Writer's
New Sheet output is a sheet entity; Add Note's output is an array of note
entities. Keyboard's image parameter is optional. Both download Live Activity
controls remain in metadata with `isDiscoverable = false`.

| Checks | Result |
| --- | --- |
| Reader narration/playback/store/intent/reader/plugin regression suites | 312 passed; zero failures |
| Final Reader capture-family, URL-save and ingest-policy checks | 25 passed; zero failures |
| Keyboard suite, including default preference validation | 91 passed; zero failures |
| Vault journal, bounded video blocks and video metadata | 9 passed; zero failures |
| Music import/journal, episode notifications, routes, queue planners, navigation and download expiry | 32 executed; 31 passed, one fixture-dependent skip, zero failures |
| Writer full suite before updating settings section assertions | 678 executed: 673 passed, three skips, two section-count assertion failures |
| Writer intent services and settings after fixing those assertions and adding navigation coverage | 24 passed; zero failures |

Reader's two stale native-ingest assertions now explicitly pin legacy/native
policy; additional tests assert current Reader stays plugin-only. The RSVP
snapshot was visually inspected and re-recorded individually after tracing the
old baseline to the earlier time-estimate/word-splitting behavior. The word-index
and RSVP-engine tests pass; no production reader layout was changed for a test.
Music's stale root-menu assertion now includes the intentional Luna Reader row.

Broader Music runs still encountered real-audio integration failures/timeouts,
including local resume/transport startup and a presented-player queue-switch
assertion. Logs repeatedly reported simulator AudioQueue startup failures and
AVFoundation `-11800`; an attempted check on a second booted simulator also did
not complete. The audit does **not** claim those playback integration tests are
green or that physical-device playback has been validated. The passing Music
subset above excludes those real-output integration checks. No simulator audio
failure was suppressed by changing production behavior or relaxing assertions.

Disk exhaustion also interrupted a later Reader run and a signing operation.
After removing only this audit's temporary build/cache artifacts, the same
prepared Reader test products passed all 312 checks. Keyboard was verified with
its own DerivedData directory after cross-scheme package-framework artifacts
caused an incremental link failure in the shared build directory. These failed
infrastructure runs are not counted as successful validation.

No live Gemini requests, real paired-Mac transfers or personal notification
automations were exercised. Native notification permission/Focus behavior and
the user's Shortcuts setup still require device-level validation. Unit tests
cover journal retention, replay, parallel writers, rollback, stable IDs, file
ownership, no-op filtering and intent data operations.
