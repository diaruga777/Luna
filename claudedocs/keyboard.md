# Luna Keyboard

Luna Keyboard is the revived standalone keyboard from `~/Desktop/clack-1`
(commit `145a00a`, including the local top-row number work). The older
`~/projects/Clack` checkout and the dependency-only `~/Desktop/Clack` folder are
left intact. The maintained app now lives in this repository.

## Targets and identity

- `LunaKeyboard`: `$(PRODUCT_BUNDLE_PREFIX).keyboard`.
- `LunaKeyboardExtension`: `$(PRODUCT_BUNDLE_PREFIX).keyboard.extension`.
- Both display `$(DISPLAY_NAME_PREFIX) Keyboard` and use `$(APP_GROUP_ID)`.
- `LunaKeyboardTests` is hosted by the `LunaKeyboard` scheme.
- iOS 26+, UIKit, Swift 5 language mode. No CocoaPods, RxSwift, RxCocoa,
  RxAnimated, SwiftyGif, or Core Data dependency.
- The app embeds `LunaKeyboardKit` once. The extension links that small kit,
  whose dependencies are keyboard code, LunaStorage, LunaModels and AppConfig.
  It does not link the reader, downloader, JavaScript, WebKit, or app design kit.

Run `ruby scripts/add_luna_keyboard_app.rb` to regenerate the target wiring.
`Config/Luna.xcconfig` remains the source of truth for product identity.

## UI and typing

The containing app uses Luna's black surfaces, white text, lavender accents,
large navigation titles, and grouped settings. Its tryout surface stays visible
when a hardware keyboard is connected. The extension follows the system keyboard
appearance instead of applying Luna's dark app theme.

English, Spanish, Latin American Spanish and Italian layouts, both symbol pages,
shift/caps lock, key previews, accents, domain suffixes, repeating backspace,
spacebar cursor movement, double-space search, sounds, haptics, blank keycaps,
text styles, a personal dictionary, text/phrase/image/GIF shortcuts, supplementary
lexicon entries, markdown styling and correction reversal are available. The
original text-style tables and popup Bezier outlines are retained. Top-row holds
add `1…0` **before** the accent alternatives, preserving access to accents.

Swipe typing compares a bounded finger path with key-center paths for up to 600
candidate words selected by language and endpoint letters. The bundled catalog
contains 12,000 frequent words for each of English, Spanish and Italian; frequency
breaks shape ties. It is a local decoder, not Apple's private swipe engine.

UITextChecker receives the preceding 256 characters and a UTF-16 range selecting
only the partial word. Adjacent QWERTY substitutions cost 0.45, other substitutions
cost 1, and the checker's original ordering breaks ties. `gell → hell` therefore
ranks ahead of `gell → sell`. Only explicitly selected languages are consulted.

## Storage and sharing

Schema 15 adds `keyboard_preferences`, `keyboard_shortcuts`, `keyboard_keywords`,
and `keyboard_dictionary` to the shared `saves.sqlite`. KeyboardStore uses the
same SavesStore connection and serial queue as other Luna APIs, with throwing
writes and bounded reads. It does not hydrate the entire saved-item list.

Media imports receive fresh UUID names in `KeyboardMedia/`. `file_holders` uses
`keyboard-shortcut:<id>` owners. Updating or deleting a shortcut releases the old
holdings, and Luna's existing triggers, tombstones and PendingDeleteReaper remove
the bytes. Imports hold the SQL write lock while creating the file. A containing-
app launch sweep removes UUID files left unowned by an interrupted transaction;
it takes the same lock, so it cannot remove a concurrently imported file.
There is no migration from Clack's old defaults, database or files.

If typing, shortcut and emoji suggestions are all empty, the strip queries recent
unarchived HTTP(S) saves and downloaded-media metadata, newest `date_added` first.
Video rows have a play prefix. Selecting either inserts the original saved URL;
the keyboard does not load a video into RAM or copy it to another media store.
Full Access is necessary to read the shared group from a third-party keyboard.
Without it, the local keyboard, swipe dictionary, emoji and text styles work.

The built-in catalog is a read-only SQLite resource, generated with
`scripts/generate_keyboard_catalog.py`. Every fully-qualified emoji and component
in the recorded Unicode version has name/word/underscore keyword mappings.
Skin-tone and joined sequences are included. ASCII art and Clack's original
symbol shortcuts are included, with custom mappings created in the app taking
priority. Emoji appearance depends on the installed iOS font version.
Sources and licenses ship beside the catalog.

## Memory and lifecycle

- Keys are drawn by one UIView with individual accessibility elements.
- At most 12 suggestion buttons are reused, regardless of typing duration.
- Only one correction reversal is retained. The old implementation accumulated
  AppliedAutocompleteSuggestion values in an unbounded PrefixTree via `scan`.
  That source path is a candidate explanation for historical growth; no old-app
  runtime comparison was made.
- UITextChecker is lazy; an unused secondary language is never queried.
- The catalog uses a 256 KB SQLite page cache. Emoji are queried, not all decoded
  into an object graph.
- The media browser is created only on request. Reused cells display one still,
  downsampled frame (240-pixel maximum) and release the compressed image source
  after decoding. File IO and ImageIO decoding run off the main thread. Only the
  explicitly copied/focused preview animates, one frame at a time; no frame arrays.
- The extension uses a 256 KB shared-store SQLite page cache and trims reclaimable
  pages on disappearance/memory warnings. Prediction ranking computes each edit
  distance once; unchanged board traits do not rebuild accessibility or redraw.
- Requests use an ephemeral URLSession with no URL cache and three connections
  per host. Selected media copying is limited to 8 MB; thumbnails to 2 MB.
- Disappearance/memory warnings cancel work and release checker, tools and history.
- Media search sends only explicit search queries to GIPHY. Remote static-image
  search (Qwant/Openverse) has been removed. Saved image shortcuts still work.
  Ordinary document typing is not sent to the provider. Search failures preserve
  local results and show a retry tile.

The historical 21.6 MB measurement is not directly comparable to a debug simulator
process. Physical-device extension memory and a pixel comparison against the
current iOS keyboard still require device verification; no numerical reduction
or pixel-perfect equivalence is asserted from the simulator checks.

## Verification

The `LunaKeyboard` scheme builds the containing app and extension and runs hosted
tests covering storage across connections, literal and phrase keywords, dictionary
language isolation, ownership cleanup, abandoned imports, recent links/videos,
archive exclusion, emoji mapping coverage, Unicode context ranges, styled-word
replacement, swipe decoding, adjacent-key ranking, view release and bounded view
counts under repeated typing. Tests use a temporary container, not user data.

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer xcodebuild test \
  -project Luna.xcodeproj -scheme LunaKeyboard \
  -destination 'platform=iOS Simulator,id=<booted iOS 26 simulator>'
```

Debug launch argument `--keyboard-tryout` opens the tryout screen for inspection.
No WebDriverAgent is installed or used on physical devices.

## Icon

`LunaKeyboard/Assets.xcassets/AppIconKeyboard.appiconset/Keyboard.png` was generated
with the built-in image tool using the current Luna Reader icon as reference:
“Luna Keyboard; silver cratered moon above an indigo horizon; lavender beveled
keyboard keys and spacebar; no letters; opaque square; match the Luna family.”
The project contains the final 1024 px asset and a smaller in-app artwork export.

Historical live checks: GIPHY and the Openverse fallback returned results. Remote
static-image search was subsequently removed (see the October update below).

## Clack todo implementation (30 September 2026)

The item-by-item record is [keyboard-todo-audit.md](keyboard-todo-audit.md), including
platform limits and checks that still need a physical device.

Schema 16 adds separate shortcut options (suggest while typing and cosmetic) and
an expiring media-search metadata cache. Existing schema-15 shortcuts retain their
previous defaults. The additive tables use foreign keys and preserve ownership.
Portable `.lunakeyboard` files carry media bytes rather than device-local paths;
imports validate their version, sizes and types and allocate fresh identifiers.
Shortcuts can be imported from Photos, marked lookup-only, shared, repaired after
missing-file detection, or explicitly removed by the cleanup action.

Corrections have a two-second eligibility window with a shrinking indicator and a
one-second undo window. Rejection suppresses immediate reapplication. Undo keeps
punctuation and trailing spaces, closing punctuation removes a separator, and URL/email traits disable
automatic prose transformations. Quotes recognize interior apostrophes. Only words
this keyboard automatically capitalized are eligible for sentence-insertion case
adjustment; at most eight words are retained and cleared on release.

Backspace dragging removes up to 256 preceding characters and restores them while
moving right. The proxy cannot set a host selection, so this is a reversible edit
preview, not a highlighted host selection. Haptics occur only when text changes.
Letters cancel repeating delete. Keyboard click sound uses the supported system API.

iPad has its own letter layout and downward flick alternatives. Preferences adds
System, Moonlight, Ocean and High Contrast themes. Keyboard Quest uses the production
surface against a disposable editor for deletion, number holds, swipe typing and
cursor movement. Its pixel sprites are drawn directly, and Show Me demonstrates the
actions. Try It Out includes the system Paste control.

Debug launch argument `--keyboard-tutorial` opens Keyboard Quest. Interactive
inspection was limited by the locked Mac; hosted tests exercise all demonstrations.

Original todo verification: **37 hosted tests passed, 0 failures** on iPhone 17 Pro,
iOS 26.2, using Xcode 26.2. The suite builds both the app and extension.


## Autocomplete follow-up (30 September 2026)

See [keyboard-autocomplete-audit.md](keyboard-autocomplete-audit.md) for all twelve
items in **Clack autocomplete improvements.pdf** and the dashes-mode addition.

Selected words now teach Luna’s personal dictionary and Apple’s spell checker;
long-press a learned suggestion to remove it. Ordinals and emphatic repeated
letters stay literal. Correction undo preserves trailing punctuation and spaces.
Abbreviations such as `e.g.` do not trigger sentence capitalization. Applied
markdown style suggestions and no-op quote wrappers disappear.

Empty editors offer the system Paste control when clipboard text is available
and Full Access is enabled. Arithmetic expressions offer a result that is applied
only when selected. Neither feature reads clipboard content while typing.

Choose **𝐁𝘐U̲ → SpongeBob** for random casing with at most two successive
cased letters in the same case. On **123**, hold **-** and slide to **Dashes** to
turn the spacebar into a literal hyphen key; choose **Spaces** in the same popup
to return. Cursor dragging remains available on the wide key.

Follow-up verification: **53 hosted tests passed, 0 failures** on iPhone 17 Pro /
iOS 26.2 using Xcode 26.2. Both app and extension built. Live gesture inspection
was limited by the locked Mac; see the audit for the remaining manual checks.

## Code review fixes (30 September 2026)

The host adapters now report nonempty text selections. Corrections, stale
suggestion replacements and reversible delete dragging require a collapsed
cursor, so replacing selected text cannot delete the preceding word. Paste
suggestions also stay hidden when the editor's contents are selected.

Backspace and the undo suggestion use the same correction-undo operation,
including its expiry check and double-space reset. URL/email fields keep double
spaces literal. Disappearance and memory cleanup discard delete-drag snapshots
and preceding/following text contexts.

Verification: all **64 hosted keyboard tests passed** on iPhone 17 Pro / iOS 26.2
with Xcode 26.2, including regressions for selected text, stale suggestion taps,
undo followed by Space, URL punctuation and drag cleanup. Both app and extension
built successfully.

Prediction resolves Spanish and Italian settings to available system locales and
checks both selected dictionaries before allowing automatic word correction. A
word recognized in either language, including a personal dictionary entry, stays
literal. The tools panel hides document suggestions and routes Tab into its
search text instead of inserting it in the host document.

Live accessibility inspection returned an empty simulator hierarchy; gesture
verification remains a manual check. Hosted tests exercise the production surface
and real UITextView selections.

## Clack storefront parity (11 October 2026)

The search list and five tabs have been replaced with Clack's single horizontal
storefront. Saved shortcuts, emoji, GIFs, and images share one query and are
interleaved. Previews are 120 points tall (85 with Compact Media Search), with
8-point spacing and a 42-point editable search field below. Search replaces the
suggestion strip and keeps the typing board visible. Search text, cursor movement,
and deletion cannot edit the host message. Closing restores the host return key.

GIF thumbnails animate by decoding one downsampled frame at a time, rather than
retaining frame arrays. Copying uses the actual image format on the pasteboard,
shows feedback on the tile, and exposes a copied preview for saving keywords.
Provider failures preserve local results and offer retry. Requests are cancelled
as soon as the query changes, including the debounce interval. Metadata uses a
new cache version so older still-image GIF thumbnails are not reused.

The style key now opens Clack's three-row style board inside the existing keyboard
height. Holding it offers the original quick styles. Gothic Bold and SpongeBob
are available by holding Gothic and Ransom respectively. Clack's key colors,
shift/delete symbols, bottom-row proportions, clipboard button, and suggestion
separators are restored.

Reference: the source in `~/Desktop/clack-1`, with dependencies from
`~/projects/Clack/Pods`, built in an isolated temporary copy. `~/Desktop/Clack`
contains dependencies only. Both apps were launched and exercised on iPhone 17
Pro / iOS 26.2. The original has Qwant disabled in its storefront; Luna keeps
image search with the existing Openverse fallback. Automated verification at
this stage: **70 hosted keyboard tests passed, 0 failures**.

Follow-up verification: **72 hosted tests passed, 0 failures**. The copied-media
preview stays pinned and collapses while browsing, survives closing search, and
updates existing keywords without duplicating shortcuts. Try It Out now accepts
image/GIF paste and renders GIF attachments with the same bounded-frame decoder.
The iPhone portrait tryout uses Clack's 210-point board and 75-point bottom inset.

Live image-search diagnosis found that Openverse now rejects anonymous page sizes
above 20. The fallback uses 20 and an explicit app User-Agent; a live `cat` request
returned 20 results. GIF results, animated local media, search entry, copy feedback,
and style-board layouts were inspected in both simulator apps. This is a targeted
keyboard UX comparison, not a claim that every containing-app screen or every
possible prediction/gesture sequence has been proven identical.


## Double-space search and memory update (13 October 2026)

Double-tap the spacebar within 0.4 seconds to open the horizontal search row and
focus its search field. The gesture consumes its two spaces; the first space's
normal word correction may already have happened. It works at the start of a
field, after digits/emoji, on symbol pages, and in dashes mode, independent of
smart-punctuation preferences. Slow spaces remain text. A selection/cursor move
or intervening key resets the gesture. Typing while search is open edits the query;
closing it returns to the document. The old search button and double-space-period
preference have been removed. VoiceOver exposes search as a space-key custom action.

Local matches are rendered immediately on each query edit. Only the remote GIF
request waits for the 200 ms debounce. Saved shortcuts, bundled media/ASCII art,
emoji, and saved links all precede remote GIFs in the same horizontal row. Shortcut
and link filtering happens in SQLite before the result limit: at most 40 shortcuts,
40 glyphs and 12 links are materialized, followed by at most 24 GIFs. Metadata cache
reads, JSON parsing and cache writes run off the typing thread. Closing the panel,
query changes and memory warnings explicitly cancel network/copy/preview work.
GIF results use GIPHY's small still thumbnails; selecting one copies the GIF itself.

Writer cooperation is best effort because UITextDocumentProxy has no supported
host-bundle identifier. Writer now has the shared App Group entitlement and publishes
an atomic timestamp while a scene is active, renewed every two seconds and removed
when its last active scene resigns/disconnects. The keyboard reads this lease only
on double-space and forwards the second literal space while the lease is valid;
Writer's existing palette retains control. A crash expires the lease after six
seconds. Both apps must run updated builds. Shared-container access must be available
(Full Access is the supported extension configuration); a missing/unreadable/expired
lease falls back to keyboard search. In iPad multitasking an active Writer alongside
another app can suppress the gesture there too; this is a foreground cooperation
signal, not guaranteed identification of the focused host app.

Verification: **82 hosted keyboard tests passed, 0 failures** on iPhone 17 Pro / iOS
26.2. Coverage includes double-space contexts, Writer forwarding/lease expiry,
instant local results, remote ranking, cancellation/release, cache bounds and
shortcut filtering before limits. Ten local query/result-snapshot updates against
250 matching shortcuts averaged about 4 ms total (about 0.4 ms per update) in the
simulator; this excludes visible-cell rendering and network time. Simulator UI
checks confirmed focused search, typing into the query, local cat emoji first and
GIFs later in the same horizontal row. A live GIPHY request returned 24 results
with 24 still thumbnails. Writer's build-for-testing succeeds and all 57 command-palette controller/overlay
tests pass. Physical-device
extension memory and host switching remain unmeasured; no numerical RAM reduction
is asserted from these checks.

## Search responsiveness and animated media audit (13 October 2026)

Clack's animated storefront is restored. GIF search uses GIPHY's small animated
rendition, with a new metadata cache version to discard still-thumbnail entries.
Previews are limited to 160 pixels on their longest edge and at most 8 fps. Frame
skipping preserves GIF timing. A serial ImageIO worker decodes one frame at a time,
explicitly removes ImageIO's decoded-frame cache, and never builds a frame array.
Remote preview downloads are capped at 2 MB; local/copied media at 8 MB. Sources
above 4 megapixels or 4096 pixels on either edge are refused for preview to bound
decode scratch space. Scrolling cells offscreen releases their source and pixels;
collection prefetching is disabled, and reused cells restart their preview.
Hidden previews pause, with playback resuming when shown.

Local search now runs on a cancellable serial worker immediately after an edit,
without waiting for the remote debounce. It no longer blocks typing on the shared
database lock. Repeated notifications for the same normalized query do not restart
search. Loading starts during the debounce and remains until both local and remote
work finish; “No results” appears only after completion. Query changes cancel copies
as well as searches. Duplicate catalog glyphs are removed before diffable snapshots,
preventing duplicate-identifier crashes for queries such as heart/party/arrow.

The tryout/tutorial editor uses UIKit's TextKit 2 stack and public text-range geometry
to position bounded animated previews over inline attachments. This avoids the
editable viewport failing to mount NSTextAttachmentViewProvider views. Attachment
bytes remain intact; removal, scrolling and disappearance release preview work.

Verification: **88 hosted keyboard tests passed, 0 failures** on iPhone 17 Pro /
iOS 26.2, with app and extension built using Xcode 26.2. New checks exercise actual
changing GIF pixels in previews and pasted attachments, the 160-pixel/8-fps limits,
hide/resume and deletion cleanup, loading across debounce/network delay, typing
while the shared store is locked, and duplicate catalog identifiers. Physical-device
extension peak memory has not been measured; these are enforced resource bounds,
not a claim of a measured device RAM footprint.

## Keyboard visual refinement (14 October 2026)

The System theme now uses neutral light/dark keycaps, pixel-aligned edges,
consistent eight-point corners, natural-aspect SF Symbols, a white active Shift
key and blue action Return keys. The styles key is a native glass `Aa` control;
the style grid includes names beneath its samples and a short page transition.
High Contrast retains an opaque styles key. Long-press choices expand toward the
available space, keep the default choice nearest the held key, and stay inside
320–440-point phone widths. Sliding onto a modifier no longer shows a character
balloon for that modifier.

Search uses a `UIGlassContainerEffect` with glass search, close and save controls.
Content tiles use continuous corners and adaptive fills, with small feedback
badges instead of covering the entire preview. Remote results retain visible
GIPHY attribution. Loading and empty states occupy the content shelf rather than
posing as selectable results. Search opens with a restrained spring, styles fade,
and pressed results respond with a small scale change; Reduce Motion disables
these animations. The existing compact heights and bounded media decoder remain.

The tryout board now has the same 220-point portrait height as the extension.
Debug `--keyboard-tryout --keyboard-light` permits light-mode inspection;
`--keyboard-system-reference` uses the system input view for comparison.

Verification: **89 hosted keyboard tests passed, 0 failures** on iPhone 17 Pro /
iOS 26.2, building both the containing app and extension. Simulator screenshots
and touch interaction covered light/dark keys, search entry and results, and a
right-expanding-side accent hold. Regression coverage includes menu bounds,
compact glass-field geometry, loading-state timing, search isolation and media
copy/save behavior. A pixel-for-pixel comparison against Apple's keyboard remains
unverified: the simulator's system keyboard stayed hidden, including in Settings,
and the locked Mac prevented changing its software-keyboard UI setting. This is
not a claim of exact system-keyboard equivalence or physical-device validation.
