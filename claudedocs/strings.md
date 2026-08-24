# Strings — one file, edited anywhere, keyed by name not by wording

Every user-visible string in all four Luna apps lives in one flat text file:

```
LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings
```

Each line is

```
"<descriptive base>_<suffix>" = "what Luna actually shows";
```

The **key is a descriptive name, never the English text** — e.g.
`"Onboarding_Util_headline_Luna"`. `<suffix>` is always one of five values:
`Luna`, `Core`, `Reader`, `Downloader`, `PriceTracker`. That split is the whole
point, twice over: copy can be rewritten in any text editor without touching
Swift, AND an app can get its own wording for a shared string by adding one
more line — no code change either way.

That is the only file. It reaches every surface two ways: LunaModels' resource
bundle (which every app, extension, clip and widget links) and a copy in each
app's own bundle for the App Intents strings — see
[Shortcuts and Siri](#shortcuts-and-siri).

## The suffix mechanism

A call site never names an app or writes its own `switch LunaApp.current`.
Code just says, e.g.,

```swift
L10n.string("Settings_shortcut_safariButtonName")
```

and `L10n` (`LunaLibraries/Sources/LunaModels/Localization.swift`) resolves
that base key at runtime by trying, in order:

1. `"<base>_<the running app's own suffix>"` — `Core` for the central **Luna**
   app, else `Reader` / `Downloader` / `PriceTracker`
   (`LunaApp.ownLocalizationSuffix`).
2. `"<base>_Luna"` — the universal default. **Every base key referenced from
   code must define this line** — it's the fallback with nowhere further to
   go, and `LocalizableStringsTests`/`strings_sync.py --check` both enforce it.

So a string every app shows identically needs only a `_Luna` line. Giving
Reader its own wording is adding exactly one more line:

```
"Settings_shortcut_safariButtonName_Luna" = "Luna";
"Settings_shortcut_safariButtonName_Reader" = "Read in Luna";
```

— with no Swift touched at all. This is why `_Core` exists as its own name
rather than reusing `_Luna` for the central app's override: `_Luna` is
reserved for the fallback tier every key has, so the central app's *own*
divergent wording (when it has any) needs a name that isn't already taken.

Two escape hatches, both in `L10n`:

- **`L10n.string(_ key:, for app: LunaApp, _ args: CVarArg...)`** resolves for
  an EXPLICIT app rather than `.current` — for showing another app's text
  (`LunaApp.displayName`, called as `owner.displayName` to name a sibling app
  in `UnsupportedSaveCopy`) and for tests that want to check a specific app's
  wording without faking a bundle identifier (`WeeklySaveLabels.promoteMenuTitle
  (for: .reader)`).
- **`L10n.stringIfPresent(_ key:, for app:)`** returns `nil` instead of falling
  back, for a caller that needs to tell "no such key" apart from "found, but
  empty" — `OnboardingSafariExtensionCopy.explainerChunks` reads
  `"<prefix>1"`, `"<prefix>2"`, … until this returns `nil`, which is how an app
  with fewer chunks than another falls out naturally with no length to keep in
  sync.

**Never hand-roll the switch this replaces.** If you find (or are about to
write)

```swift
switch LunaApp.current {
case .luna: return L10n.string("A")
case .reader: return L10n.string("B")
...
}
```

collapse it to one `L10n.string("SomeKey")` call and move `A`/`B`/… into
`SomeKey_Core`/`SomeKey_Reader`/… in the strings file. `WeeklySaveLabels.swift`
and `OnboardingStrings.Definition`/`ChunkedDefinition` are the two worked
examples in the codebase; `Definition` in particular used to carry a
`.shared`/`.perSurface` enum in Swift that did exactly this switching — it now
just stores a key and defers to `L10n.string(key, for:)`.

## Editing on a phone

Copy the file off, edit the right-hand sides, copy it back. Nothing else is
required — no regeneration step, no build step, no key to look up.

Three rules, and the test suite enforces all three:

1. **Only edit inside the right-hand quotes.** The left-hand side is the
   lookup key. Changing it doesn't rename anything — it detaches the line,
   and `L10n` falls all the way through to showing the raw key (there's no
   English to fall back to anymore, since the key was never English — this is
   the one regression from the old key-is-the-English scheme, traded for the
   ability to reword per app).
2. **Keep every `%@`, `%lld`, `%1$@` marker**, in a consistent order, ACROSS
   every suffix of one base key — `_Core`/`_Reader`/`_Downloader`/
   `_PriceTracker`/`_Luna` are substituted with the same call-site args, so
   they must all take the same shape. Dropping one leaves an argument with
   nowhere to go; adding one invents an argument the code never passed.
3. **Keep the punctuation**: opening quote, `=`, closing quote, trailing `;`.
   A line that loses its semicolon takes the rest of the file down with it —
   `NSDictionary(contentsOf:)` returns nil for the whole table, and every
   string in the app falls back to its key at once.

`\n` in a value is a real line break. A literal `"` inside copy is `\"`.

## Naming and grouping — hand-authored, not mechanical

Unlike the old key-is-the-English file, **grouping and comments in this file
are a permanent, hand-maintained asset** — `strings_sync.py` never re-sorts or
re-groups it (see below). A key is `<ScreenOrFeaturePrefix>[_<SubGroup>]_
<description>`, e.g. `Onboarding_Safari_explainerChunk1`,
`Settings_email_testSendFailedTitle`. The two rules that make the file
pleasant to read straight through:

- **Strings shown together, or with a natural reading order, share a prefix**
  so they sort together.
- **Alphabetical key order should match on-screen reading order.** For a
  numbered list of more than a few items, zero-pad the ordinal so it doesn't
  break past 9 — `ShareSetupPractice_feature01` … `_feature23` is the worked
  example. For a pair with no natural digit, pick names where alpha order
  already matches (`headline1Initial`/`headline2Final`, not
  `headlineInitial`/`headlineFinal`).
- Every group gets a `/* ===== Name — what/where ===== */` header comment
  above it explaining what the group is and where it's shown.

Generic, truly-shared UI chrome ("Cancel", "Done", "Save" as a plain button)
lives under one `Common_*` prefix rather than being duplicated with a
different name per screen — the point is that changing "Cancel" everywhere is
one edit, not a hunt. Don't reach for `Common_*` for text that only
*coincidentally* matches another screen's wording today; two independent
pickers that both happen to have a "System" option stay separate
(`Settings_appearance_system` vs. `Settings_readerFont_system`) since they may
need to diverge later.

## Adding a string in code

Call `L10n.string("Some_Descriptive_Key")`, then add
`"Some_Descriptive_Key_Luna" = "The actual copy.";` to the file, in whichever
existing group it reads with (by hand — the sync script doesn't guess this).
If the copy substitutes a value, pass it as a separate argument rather than
interpolating into the key:

```swift
// wrong — a key must never itself be interpolated:
L10n.string("Tried \(count) times")
// right:
L10n.string("SomeCard_attemptFooter", count)
// strings file:
"SomeCard_attemptFooter_Luna" = "Tried %lld times";
```

```sh
scripts/strings_sync.py --check    # what has drifted, both directions
scripts/strings_sync.py --write    # append missing keys as placeholders,
                                    # drop lines no code references
```

`--write` is deliberately conservative compared to the old file's version: it
never re-sorts or re-groups (grouping is hand-authored now), and a newly
"adopted" key is appended under a loud `NEEDS REVIEW` marker with its own key
text as a placeholder value — a human still has to write the real copy and
move it into its proper group. Removing dead lines (a base+suffix combination
no code references, or an entry whose key doesn't end in a recognized suffix
at all) IS still automatic.

The script also recognizes two indirection points that aren't `L10n` calls
themselves but still need a required entry: `OnboardingStrings.Definition(key:
"…")` and `ChunkedDefinition(keyPrefix: "…")` — see
[The suffix mechanism](#the-suffix-mechanism).

## What is deliberately NOT in the file

Not every Swift string literal is copy, and wrapping the wrong ones makes the
file unreadable and the app fragile:

- **`OnboardingStrings.Accessibility`** — UI-test identifiers
  (`onboarding.safari.page.headline`). They are contracts with the test suite,
  not words anyone reads. Still constructed via `Definition(shared:)`, the one
  surviving use of that initializer — a raw value with no `L10n` lookup at
  all.
- **`OnboardingStrings.AnimationKeys`** — CALayer animation keys, same
  treatment.
- **Markup assembly**, like the `<h1>…</h1>` fragment in
  `ShareSetupPractice.fallbackHTMLBody`.
- **Hostnames and URLs** that the ingest pipeline matches on.
- **Dynamic, non-authored text** — an error's own `localizedDescription`, a
  save's real title. `L10n` has nothing to look up for text nobody wrote, so
  it's just a plain `String` (or `"\(error)"`), never routed through a key.

The mock InstaTok/Amayzon page copy *is* in the file — it is displayed, and
the onboarding practice flow reads better when its wording can be tuned.

## Shortcuts and Siri

App Intents metadata — intent names, descriptions, parameter titles, the
result types Shortcuts displays — is in the same file as everything else, but
it gets there differently, and it does NOT participate in the per-app suffix
fallback.

Xcode extracts that metadata at **build time**, and the metadata processor
rejects anything that isn't a string literal — no function call, so no
`L10n.string(key, for: app)`. Concretely: a plain `title: "Save"` becomes
`title: "Intents_save_title_Luna"` — the literal in the Swift source IS the
already-suffixed, concrete key, always ending `_Luna` (there is no runtime
resolution step to pick a different suffix for these). One exception worth
knowing: `AppEnum.caseDisplayRepresentations` is ALSO build-time-extracted
(same "must be a literal" restriction as `typeDisplayRepresentation`) even
though it doesn't match any of the four shapes below by name — it showed up
as a hard build failure (`'LocalizedStringResource' must be initialized with
a call to its initializer or a string literal`) rather than a silent
scanner miss, which is how this was caught.

- `strings_sync.py` finds these literals by SHAPE rather than by call
  (`static let … : LocalizedStringResource =`, `IntentDescription(…)`,
  `@Parameter`/`@Property``(title:description:)`, `typeDisplayRepresentation`),
  and only in `Luna/Mail/Intents/` and the Live Activity widget, because
  `title:` is far too common a label to match everywhere — and even there, a
  plain per-instance `DisplayRepresentation(title: "\(dynamic)")` VALUE
  (runtime content, not metadata) is excluded by name. Multi-line `"""`
  descriptions are joined the way Swift joins them, backslash continuations
  and all.
- **The app targets copy the one file into their own bundles**, via a plain
  resource reference added by `scripts/add_strings_to_app_bundles.rb`. Re-run
  it after adding an app or widget target; it is idempotent, and
  `LocalizableStringsTests.testAppBundleCarriesTheSameTable` fails if a host is
  missing its copy or the copies have drifted.

Two things stay in Swift and are not editable this way:

- **`AppShortcut` phrases and `shortTitle`s** (`Luna/Mail/Intents/LunaShortcuts.swift`).
  These belong to a third mechanism (`AppShortcuts.strings`) and are Siri
  grammar rather than copy — `"Save this screen with \(.applicationName)"` is a
  spoken trigger, and rewording it changes what Siri responds to.
- **`BundledShortcut.displayName`.** iOS takes that name from the imported
  `.shortcut` file (one per app: `Luna.shortcut`, `Luna Reader.shortcut`, …), so
  the constant and the filename have to agree; editing the copy alone would
  rename it in Luna's prose while the Action Button picker kept the old name.
  Rename the resource and the constant together. It reads the same words as
  `LunaApp.displayName` (now `L10n.string("LunaApp_displayName", for: self)`)
  and deliberately does not share its lookup — that one is copy and may be
  reworded, this one is a filename.

## The build-level guarantee

One source file, but a built app carries **eight or so copies of it**, each
made by a different, independently-tracked copy task:

| copy | who makes it |
| --- | --- |
| `LunaLibraries_LunaModels.bundle/en.lproj/Localizable.strings` | SwiftPM, from `.process("Resources")` on LunaModels — verbatim bytes |
| the same bundle again inside every embedded `.appex`, App Clip and widget | each of those targets links LunaModels and embeds its own copy |
| `<App>.app/en.lproj/Localizable.strings` | `CopyStringsFile`, from the resource reference `add_strings_to_app_bundles.rb` adds — converted to a binary plist, so it is NOT byte-identical to the source |

Every one of those is an up-to-date decision the build system makes on its
own, and **nothing about a stale one is visible from inside the app**: it
reads as "my copy edit didn't take", which invites re-editing copy that was
already right — or, worse, ships wording nobody wrote.

That is not hypothetical. Measured on Xcode 26.2: with an app fully built, put
an older table into `<App>.app/LunaLibraries_LunaModels.bundle/en.lproj/
Localizable.strings` and build again — the embed copy is **not** re-run, and
the build reports `** BUILD SUCCEEDED **` while the app carries the old table.
The realistic way to get into that state is an **interrupted build**: the
top-level `LunaLibraries_LunaModels.bundle` product is updated early, and a
build killed after that leaves every copy nested inside the `.app` a version
behind. A products directory holding an app that this scheme did not rebuild
(all four apps share one `Build/Products` directory) is the other way.

So every app target ends with a **`Verify bundled strings table`** build
phase, which runs

```sh
scripts/check_bundled_strings.py <the source> "$TARGET_BUILD_DIR/$WRAPPER_NAME"
```

Every `Localizable.strings` anywhere under the `.app` must parse to the same
key/value table as the source; a mismatch is REWRITTEN IN PLACE — the script
redoes whichever copy task produced that file (a verbatim copy for the SwiftPM
resource bundle, a `plutil -convert binary1` for the app-root `CopyStringsFile`
output, detected from the file's own leading bytes) and prints a `note:` naming
what it rewrote, so the build ships the real table instead of merely detecting
that it wouldn't have. Comments, ordering and storage format are not compared —
a `.strings` file is an old-style plist and the app-root copies are binary
plists, so both sides go through `plutil` and are compared as tables, which is
what the app can actually read. Copies that are byte-identical to the source
skip parsing entirely, so the whole check costs about 0.1s and it is
deliberately **always out of date**: the thing it distrusts is exactly the
incremental logic that would let it be skipped.

The one case it can't fix by rewriting bytes is a bundle root with no `en.lproj`
copy of its own at all — that means the Resources build phase reference is
missing, so nothing would re-create the file on the next build either. That
stays an `error:` telling you to run `scripts/add_strings_to_app_bundles.rb`;
everything else self-heals.

Three things to know about it:

- It is installed by **`scripts/add_strings_check_phase.rb`** — re-run after
  adding an app target, the same way `add_strings_to_app_bundles.rb` is. Only
  the four APPS get the phase; everything else that carries a copy is embedded
  inside one of them, so walking the `.app` covers it.
- **It only guarantees a build that ran to the END.** An interrupted build
  never reaches its last phase, and that half-updated products directory is
  exactly what a hand-run `simctl install` reaches for. So
  `scripts/install_all_luna_apps.sh` runs the same check-and-repair on each
  `.app` immediately before installing it. If you install by hand, run the
  checker by hand.
- The unit-test bundle is **skipped** (`SKIPPED_SUFFIXES`): a plain
  `xcodebuild build` does not rebuild `LunaTests.xctest`, so in a derived-data
  path that has also run the suite it legitimately lags, and it is never
  installed or shipped. The test build checks its own copies from the inside
  instead — see `LocalizableStringsTests` below.

`LocalizableStringsTests.testAppBundleCarriesTheSameTable` is NOT this
guarantee and never was: it runs inside the test host, so it can only compare
the app's copy against LunaModels' copy *in the build it is running in*, and it
cannot see the source tree at all. Two copies made from the same stale input
agree with each other perfectly. The build phase is the only thing that
compares a built artifact to the file on disk.

## Info.plist strings

There is no `InfoPlist.xcstrings`. There used to be three (`Luna/`, `LunaShare/`,
`LunaAction/`) and they were pure churn: each was shared by four targets through
a synchronized group, and every build rewrote `CFBundleDisplayName` /
`CFBundleName` with whichever target built last — so an `AllLunaApps` build left
the central app's catalog claiming it was called "Luna Price Tracker". Nothing
shipped wrong (untranslated entries are dropped from the emitted table, and each
app's real name comes from its own `Info.plist`), but every full build dirtied
the tree.

The usage descriptions those catalogs held are already in the `Info.plist`s
verbatim, and the display names come from `Config/Luna.xcconfig` per target,
which is where per-target values belong. Deleting the catalogs lost nothing —
there were no translations — and Xcode does not recreate one that isn't in the
project. If Luna ever ships a second language, add per-TARGET catalogs rather
than one shared file, for the same reason each app has its own entitlements.

## How the copy reaches the screen

`L10n` (`LunaLibraries/Sources/LunaModels/Localization.swift`) is the only
lookup point. `L10n.string(…)` returns a resolved `String`, substituting any
trailing `args` via `String(format:)`; `L10n.resource(…)` returns a
`LocalizedStringResource` for the system APIs that demand one (ActivityKit
alerts, and the computed `localizedStringResource` / `displayRepresentation`
properties on App Intents errors and entities) — it resolves the app-suffix
choice EAGERLY, in-process, at the call site, rather than deferring to
whichever process ends up rendering the resource, since that process might not
share this one's app identity. Both resolve against `Bundle.module` —
LunaModels' resource bundle — which is embedded in every app, extension, clip
and widget that links LunaModels. One file, one lookup, every surface.

### The bug this replaced, and the setting that must not be removed

Before the key-is-the-English scheme even existed, the copy lived in two
`.xcstrings` catalogs and **none of it was ever read**:
`LunaLibraries_LunaModels.bundle` shipped containing an Info.plist and nothing
else, because the package had no `defaultLocalization`. So: **`defaultLocalization:
"en"` in `LunaLibraries/Package.swift` is load-bearing.** Remove it and the
table vanishes from the bundle again, with no build error and no visible
change until someone edits a value and it doesn't take.
`LocalizableStringsTests` reads the table out of the *built* bundle rather than
the working tree for exactly this reason.

## Tests

`LunaTests/LocalizableStringsTests.swift`:

- the shipped table exists in the bundle, parses, and is populated
- every key resolves through the same bundle lookup `L10n` uses
- every entry's key ends in a recognized suffix (`_Luna`/`_Core`/`_Reader`/
  `_Downloader`/`_PriceTracker`) — an unreachable key is dead weight or a typo
  away from becoming one
- every base key that has an app override also has a `_Luna` fallback
- every value substitutes exactly what its SUFFIX SIBLINGS do (specifier
  parity across `_Core`/`_Reader`/`_Downloader`/`_PriceTracker`/`_Luna` for one
  base key — not key-vs-value the way the old file checked it, since the key
  no longer carries specifiers)
- the Shortcuts/Siri table parses and still carries the intent names, checked
  against their concrete `Intents_*_Luna` keys directly (no runtime fallback
  to check for these)

A test that references a screen's copy to build an expected value (e.g. an
accessibility-label match in a UI test) has to use the new key too —
`L10n.string("Play")` no longer resolves to `"Play"`, it resolves to nothing,
since `"Play"` was never a base key under this scheme. `RSVPEyeTrackingTests`/
`RSVPEyeTrackingReliabilityTests`/`ArticleCardsChromeTests` all had one such
site each, updated during this migration.

Code-to-file drift is `scripts/strings_sync.py --check`, not a unit test: the
tests run on a simulator with no access to the source tree.
