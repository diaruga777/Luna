# Luna

Luna is a collection of native Apple apps and a Mac companion. The iOS/iPadOS
apps share Swift packages and, where relevant, one App Group. Luna Mac provides
paired file and music access. Source editing and app build/deployment now live
in the standalone [Orbit](https://github.com/diaruga777/Orbit) product.

## Apps

| App | Xcode scheme | What it does |
| --- | --- | --- |
| Luna Reader | `LunaReader` | Saves articles, documents, social/video/audio links and products; includes readers, Kindle export, friend sharing and price tracking. Media and transcript plugins are installed separately. |
| Luna Keyboard | `LunaKeyboard` | A standalone keyboard with shortcuts, swipe typing, emoji, and Luna link/video suggestions. |
| Luna Music | `LunaMusic` | A MusicKit and MediaPlayer library player with search, playlists, Siri, widgets, and a queue Live Activity. |
| Luna Vault | `LunaVault` | An encrypted, search-first file library for on-device, iCloud, or a user-owned Mac storage. |
| Luna Writer | `LunaWriter` | A native writing and document library app. |

Luna and Keyboard share `saves.sqlite`. Vault and Writer have separate file
stores, and Music has its own library.
See [`claudedocs/`](claudedocs/) for feature and architecture details.

## Requirements

- macOS with Xcode and its matching command-line tools installed. The project
  targets iOS 26; the repository's development setup uses Xcode 27 beta with
  an iOS 27 simulator, while archives use stable Xcode 26.2. Use an installed
  simulator runtime supported by your Xcode. Open `Luna.xcodeproj` once if
  Xcode needs to resolve Swift packages.
- SwiftPM dependencies resolve from the package manifests; no private package
  registry credentials are expected.
- For physical-device installation or distribution, use your own Apple
  Developer team and provisioning. Simulator builds do not need Luna's signing
  certificate.
- Luna Mac builds with Swift 6 / the Xcode command-line tools and runs on macOS
  15 or later.

## Clone and build an app

```sh
git clone https://github.com/diaruga777/Luna.git
cd Luna
xcodebuild -list -project Luna.xcodeproj
xcrun simctl list devices available
```

Choose an installed iOS Simulator device name from the last command, then
build and launch an app (replace the scheme and device as needed):

```sh
xcodebuild build -project Luna.xcodeproj -scheme LunaReader \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .build-dd
open .build-dd/Build/Products/Debug-iphonesimulator/LunaReader.app
```

The App Store listing remains **Luna: Save Anything**, and the bundle ID remains
`com.hsanabria.luna`. The former standalone Reader, Shopping/Price Tracker and
Downloader apps are retired. `LunaReader` is the unit-test host.

To install all five apps handled by the helper on a booted simulator,
run `scripts/install_all_luna_apps.sh`; pass a simulator name or UDID to select
one. A physical device needs Developer Mode, a trusted connection, and a team
with matching registered identifiers and capabilities.

## Signing with your own Apple Developer team

The repository does not need a developer certificate or private key. Xcode's
`DEVELOPMENT_TEAM` build setting is intentionally unset in the shared project.
For your local checkout, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and replace the placeholder with your Team ID. The
ignored local file is automatically included by `Config/Luna.xcconfig` and
survives normal Git updates without becoming part of a commit.
For an iOS simulator build, Xcode uses local simulator signing. For a physical
device, pass your own Team ID for that build, for example:

```sh
xcodebuild build -project Luna.xcodeproj -scheme LunaReader \
  -destination 'platform=iOS,id=YOUR_DEVICE_UDID' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID
```

The default bundle IDs and App Group belong to the upstream Luna app. To sign
your own fork onto devices, edit `LUNA_NAMESPACE` and `COMPANY_PREFIX` at the
top of [`Config/Luna.xcconfig`](Config/Luna.xcconfig) to a reverse-DNS namespace
you control, then register the resulting app IDs and provision the shared App
Group/iCloud capabilities required by the app you are building. You can also
select your team in Xcode's Signing & Capabilities UI; Xcode will write that
choice into the project file, so avoid committing personal signing changes.

You can instead set `DEVELOPMENT_TEAM=YOUR_TEAM_ID` on an `xcodebuild` command
or choose the team in Xcode's Signing & Capabilities UI. That UI writes its
selection into the project file, so keep personal signing changes uncommitted.
Never commit certificates, `.p12`/`.p8` files, provisioning profiles, API
private keys, or account passwords.

Music, Keyboard and Writer embed their own Share extensions. Each extension needs
an explicit App ID (`$(PRODUCT_BUNDLE_PREFIX).music.share`, `.keyboard.share`,
or `.writer.share`) and its own development profile with the shared App Group
enabled. A wildcard profile cannot supply App Groups. After adding a target,
open the project in Xcode with automatic signing and your team selected for the
app and extensions; let Xcode register the IDs and update their profiles before
retrying Orbit. If an account appears signed in but build tools cannot load its
session, unlock the Mac and check Xcode's account/team state before reauthenticating.

Share-signing verification (2026-11-02): Xcode registered the three missing Share
App IDs and generated development profiles using the existing signed-in team.
Committed detached builds of LunaMusic, LunaKeyboard and LunaWriter passed.
Strict app signatures and every embedded extension's App Group, exact App ID,
registered-phone eligibility and provisioning lifetime were verified. No source
entitlement was removed and no credential or signing identity was changed.
No physical phone access, installation, renewal, App Store submission or marketplace
acceptance was performed by this verification.

## Orbit and Luna Mac

Luna Code and its Mac build/install services moved to the standalone open source
[Orbit](https://github.com/diaruga777/Orbit) product. See Orbit’s README for its
source editor, free Apple account setup, scheduled phone installs and agent MCP.

Luna Mac continues to serve Luna Vault and Luna Music. Build it with
`LUNA_MAC_SIGNING_IDENTITY` set to the exact certificate used for your existing
Luna Mac app; see [`AGENTS.md`](AGENTS.md) and
[`claudedocs/mac-connection.md`](claudedocs/mac-connection.md).

## Credential and secret review

The shared project contains no Apple signing certificate or private key, App
Store Connect API private key, password, or Tailscale auth key. The upstream
bundle namespace, App Store URL, and Team ID were public account identifiers;
the Team ID is no longer checked into the Xcode project. Mac signing identity
is now supplied through `LUNA_MAC_SIGNING_IDENTITY` when needed. Apple credentials for app distribution must be configured by the Mac's owner.

## More contributor notes

Repository-specific agent instructions are in [`AGENTS.md`](AGENTS.md).
Feature notes and manual workflows are in [`claudedocs/`](claudedocs/).

Vault and Music keep last-known Mac disk usage, and Music keeps YouTube audio
availability. Pages show saved data while refreshing and keep it if the Mac is
offline. These display caches are scoped to the paired Mac.
