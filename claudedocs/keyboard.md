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
spacebar cursor movement, double-space period, sounds, haptics, blank keycaps,
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
- The media browser is created only on request. Reused cells load a downsampled
  first frame, cancel stale requests and do not retain animated GIF frame arrays.
- Requests use an ephemeral URLSession with no URL cache and three connections
  per host. Selected media copying is limited to 8 MB; thumbnails to 1 MB.
- Disappearance/memory warnings cancel work and release checker, tools and history.
- Media search sends only explicit search queries to GIPHY/Qwant (with an Openverse CC0/public-domain fallback). Ordinary typed
  text is not sent to these services. Search failures are shown in the panel.

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

Live checks: GIPHY returned results; the old Qwant endpoint returned HTTP 403,
so image search falls back to Openverse, which returned results in the same check.

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

Choose **Aa → Styles → SpongeBob** for random casing with at most two successive
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

Verification: all **59 hosted keyboard tests passed** on iPhone 17 Pro / iOS 26.2
with Xcode 26.2, including regressions for selected text, stale suggestion taps,
undo followed by Space, URL punctuation and drag cleanup. Both app and extension
built successfully.
