# Strings — one file, edited anywhere

Every user-visible string in all four Luna apps lives in one flat text file:

```
LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings
```

Each line is

```
"the original English" = "what Luna actually shows";
```

The **key never changes**; the **value** is the copy. That split is the whole
point: copy can be rewritten in any text editor, on any device, without opening
Xcode and without touching a line of Swift.

That is the only file. It reaches every surface two ways: LunaModels' resource
bundle (which every app, extension, clip and widget links) and a copy in each
app's own bundle for the App Intents strings — see
[Shortcuts and Siri](#shortcuts-and-siri).

## Editing on a phone

Copy the file off, edit the right-hand sides, copy it back. Nothing else is
required — no regeneration step, no build step to "compile" the strings, no key
to look up. The file is the resource that ships.

Three rules, and the test suite enforces all three:

1. **Only edit inside the right-hand quotes.** The left-hand side is the lookup
   key. Changing it doesn't rename anything — it detaches the line, and the app
   falls back to displaying the key. (Which is the original English, so a
   mistake degrades to "unedited", never to a blank or a raw identifier.)
2. **Keep every `%@`, `%lld`, `%1$@` marker**, in a consistent order. These are
   where a name, count, price or date gets substituted. Dropping one leaves an
   argument with nowhere to go; adding one invents an argument the code never
   passed. If you need to *reorder* them, switch the value to the positional
   form — `%1$@ … %2$lld` — and the arguments follow the numbers.
3. **Keep the punctuation**: opening quote, `=`, closing quote, trailing `;`.
   A line that loses its semicolon takes the rest of the file down with it —
   `NSDictionary(contentsOf:)` returns nil for the whole table, and every string
   in the app falls back to its key at once.

`\n` in a value is a real line break. A literal `"` inside copy is `\"`.

Sections (`/* ===== Settings ===== */`) are cosmetic grouping to make the file
scannable; the parser ignores them and they can be reordered freely.

## Adding a string in code

Call `L10n.string("Your new sentence.")`. It works immediately — an unknown key
falls back to itself — and then:

```sh
scripts/strings_sync.py --check    # what has drifted, both directions
scripts/strings_sync.py --write    # adopt new keys, drop dead ones, re-sort
```

`--write` adds any literal it finds in the source, removes entries no code
references any more, and rewrites the file grouped and alphabetised.

The script parses the Swift itself, including interpolation: it turns
`L10n.string("Links (\(count))")` into the pattern `Links (…)` and matches it
against the file's `Links (%lld)`. What it will **not** do is invent a specifier
for an interpolated string it has never seen — `\(count)` could be `%lld` or
`%@`, and guessing wrong is a crash. Those are printed for a human to add once,
by hand. There are around fifty interpolated strings in the whole codebase.

## What is deliberately NOT in the file

Not every Swift string literal is copy, and wrapping the wrong ones makes the
file unreadable and the app fragile:

- **`OnboardingStrings.Accessibility`** — UI-test identifiers
  (`onboarding.safari.page.headline`). They are contracts with the test suite,
  not words anyone reads.
- **`OnboardingStrings.AnimationKeys`** — CALayer animation keys.
- **Markup assembly**, like the `<h1>…</h1>` fragment in
  `ShareSetupPractice.fallbackHTMLBody`.
- **Hostnames and URLs** that the ingest pipeline matches on.

The mock InstaTok/Amayzon page copy *is* in the file — it is displayed, and the
onboarding practice flow reads better when its wording can be tuned.

## Shortcuts and Siri

App Intents metadata — intent names, descriptions, parameter titles, the result
types Shortcuts displays — is in the same file as everything else, but it gets
there differently.

Xcode extracts that metadata at **build time**, and the metadata processor
rejects anything that isn't a string literal: `static let title:
LocalizedStringResource = "Save"` cannot become an `L10n` call. At runtime
though, the literal resolves against a strings table in the **host** bundle —
the app's own, not LunaModels'. So two things bridge the gap:

- `strings_sync.py` finds these literals by SHAPE rather than by call
  (`static let … : LocalizedStringResource =`, `IntentDescription(…)`,
  `@Parameter(title:description:)`, `typeDisplayRepresentation`), and only in
  `Luna/Mail/Intents/` and the Live Activity widget, because `title:` is far too
  common a label to match everywhere. Multi-line `"""` descriptions are joined
  the way Swift joins them, backslash continuations and all.
- **The app targets copy the one file into their own bundles**, via a plain
  resource reference added by `scripts/add_strings_to_app_bundles.rb`. Re-run it
  after adding an app or widget target; it is idempotent, and
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
  `LunaApp.displayName` and deliberately does not share its lookup — that one is
  copy and may be reworded, this one is a filename.

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
lookup point. `L10n.string(…)` returns a resolved `String`;
`L10n.resource(…)` returns a `LocalizedStringResource` for the system APIs that
demand one (ActivityKit alerts, and the computed `localizedStringResource` /
`displayRepresentation` properties on App Intents errors and entities). Both
resolve against `Bundle.module` — LunaModels' resource bundle — which is
embedded in every app, extension, clip and widget that links LunaModels. One
file, one lookup, every surface.

### The bug this replaced, and the setting that must not be removed

Before this, the copy lived in two `.xcstrings` catalogs and **none of it was
ever read**. `LunaLibraries_LunaModels.bundle` shipped containing an Info.plist
and nothing else: the package had no `defaultLocalization`, so neither
swift-build nor Xcode ever placed a strings table inside it, and all ~580
`L10n.string(…)` call sites silently fell back to their keys. It went unnoticed
for as long as it did precisely because the key *is* the English — the apps
looked correct while the localization layer did nothing at all.

So: **`defaultLocalization: "en"` in `LunaLibraries/Package.swift` is
load-bearing.** Remove it and the table vanishes from the bundle again, with no
build error and no visible change until someone edits a value and it doesn't
take. `LocalizableStringsTests` reads the table out of the *built* bundle rather
than the working tree for exactly this reason — a test that read the source file
would have passed the entire time the feature was dead.

## Tests

`LunaTests/LocalizableStringsTests.swift`:

- the shipped table exists in the bundle, parses, and is populated
- every key resolves through the same bundle lookup `L10n` uses
- every value substitutes exactly what its key substitutes (specifier parity,
  positional or not)
- the Shortcuts/Siri table parses and still carries the intent names

Code-to-file drift is `scripts/strings_sync.py --check`, not a unit test: the
tests run on a simulator with no access to the source tree.
