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

A second, much smaller file holds the Shortcuts/Siri strings — see
[Shortcuts and Siri](#shortcuts-and-siri) for why it has to be separate.

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

`Luna/en.lproj/Localizable.strings` holds the App Intents metadata: intent
names, descriptions, parameter titles, and the result types Shortcuts displays.

It is separate because App Intents metadata is extracted by Xcode at **build
time** and read from the app's own bundle. `static let title:
LocalizedStringResource = "Save"` cannot become a lookup — the App Intents
metadata processor requires a literal — but it *can* resolve that literal
against this table at runtime. So the Swift stays a literal and the copy is
still editable here.

Two things are in neither file, and stay in Swift:

- **`AppShortcut` phrases and `shortTitle`s** (`Luna/Mail/Intents/LunaShortcuts.swift`).
  These belong to a third mechanism (`AppShortcuts.strings`) and are Siri
  grammar rather than copy — `"Save this screen with \(.applicationName)"` is a
  spoken trigger, and rewording it changes what Siri responds to.
- **The two Live Activity intent titles** ("Cancel Download", "Resume
  Download"). They resolve against the widget's own bundle, not the app's. Their
  accessibility labels — the part actually read aloud — *are* in the main file.

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
