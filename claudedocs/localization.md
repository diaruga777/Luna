# Localization

Luna uses Xcode string catalogs for native UI and WebExtension message bundles
for the Safari extensions. English is the source language; translators add
localizations directly in Xcode without changing Swift source.

## Catalog ownership

- `LunaLibraries/Sources/LunaModels/Resources/Localizable.xcstrings` is the
  shared catalog for UIKit copy used by the app shells, App Clips, and SwiftPM
  feature libraries. `LunaModels.L10n` always resolves it from the
  `LunaModels` SwiftPM resource bundle, so all three apps and their extensions
  use the same translations.
- `Luna/Localizable.xcstrings` contains compiler-extracted App Intent and
  Shortcuts metadata. Those APIs require `LocalizedStringResource` and are
  discovered in the app target.
- `LunaDownloaderLiveActivity/Localizable.xcstrings` contains the Live Activity
  widget and its App Intent copy.
- `Luna/InfoPlist.xcstrings`, `LunaShare/InfoPlist.xcstrings`, and
  `LunaAction/InfoPlist.xcstrings` contain the user-facing privacy usage
  descriptions for their corresponding target families.
- `LunaSafari/Resources/_locales/en/messages.json` contains the Safari
  WebExtension name, description, button labels, and toast copy. The manifest
  declares English as its default locale and uses `__MSG_*__` placeholders.

## Adding native copy

UIKit APIs generally accept a resolved `String`, so new visible copy must use:

```swift
titleLabel.text = L10n.string("Reading List")
statusLabel.text = L10n.string("Downloaded \(count) items")
```

Import `LunaModels` when the calling module is not already in that module.
Prefer a complete sentence or message over separately translated fragments.
The compiler converts interpolations to positional format placeholders in the
catalog.

Keep using compiler-native localized literals for App Intents and the Live
Activity's SwiftUI views:

```swift
static let title: LocalizedStringResource = "Save"
Text("Open Photos Settings")
```

ActivityKit alerts that require a deferred `LocalizedStringResource` use
`L10n.resource(...)`, which points the system lookup at the shared SwiftPM
bundle.

The migration helper at `scripts/localize_visible_literals.rb` audits and wraps
common UIKit presentation contexts. It deliberately excludes identifiers,
symbols, file names, protocol values, App Intent literals, and test fixtures;
review its diff rather than treating it as a semantic replacement for a UI
copy audit.

## Refreshing extracted catalogs

Xcode automatically extracts strings for targets that own their catalog.
Luna's shared catalog intentionally lives in `LunaModels`, while most calls are
compiled in sibling SwiftPM targets. To refresh every `.stringsdata` file for a
catalog update, build the `Luna`, `LunaReader`, `LunaDownloader`, and
`LunaPriceTracker` schemes with:

```sh
xcodebuild build -project Luna.xcodeproj -scheme <scheme> \
  -destination 'generic/platform=iOS Simulator' \
  SWIFT_EMIT_LOC_STRINGS=YES ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
```

Then use Xcode's `xcstringstool sync` with the emitted `.stringsdata` files to
update the appropriate catalog. Do not hand-author interpolation format keys:
the compiler records the argument ordering and types.

For a new Safari locale, copy `_locales/en/messages.json` to
`_locales/<locale>/messages.json`, translate only each `message`, and leave the
message keys unchanged.
