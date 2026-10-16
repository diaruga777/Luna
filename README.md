# Luna

Luna is a collection of native Apple apps and a Mac companion. The iOS/iPadOS
apps share Swift packages and, where relevant, one App Group. Luna Code is a
source editor for working with projects on a paired Mac; the Mac companion
provides file access, SourceKit intelligence, builds, and optional TestFlight
deployment.

## Apps

| App | Xcode scheme | What it does |
| --- | --- | --- |
| Luna Reader | `Luna` or `LunaReader` | Reads articles, paywalled pages, and documents, with scrolling and RSVP speed-reading modes and Send to Kindle. |
| Luna Downloader | `LunaDownloader` | Saves social, video, and audio links; includes optional friend sharing. |
| Luna Price Tracker | `LunaPriceTracker` | Tracks product prices. |
| Luna Keyboard | `LunaKeyboard` | A standalone keyboard with shortcuts, swipe typing, emoji, and Luna link/video suggestions. |
| Luna Music | `LunaMusic` | A MusicKit and MediaPlayer library player with search, playlists, Siri, widgets, and a queue Live Activity. |
| Luna Vault | `LunaVault` | An encrypted, search-first file library for on-device, iCloud, or a user-owned Mac storage. |
| Luna Code | `LunaCode` | An iPhone/iPad source editor with local drafts and syntax checks, plus Mac-backed completion, diagnostics, builds, and TestFlight jobs. |
| Luna Writer | `LunaWriter` | A native writing and document library app. |

The three link apps, Vault, Keyboard, and Writer use the shared `saves.sqlite`
store where applicable. Music has its own library and does not use that store.
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
xcodebuild build -project Luna.xcodeproj -scheme LunaCode \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .build-dd
open .build-dd/Build/Products/Debug-iphonesimulator/LunaCode.app
```

Other runnable schemes are listed above. `Luna` is the Reader test host;
`LunaDownloader`, `LunaPriceTracker`, and the other app schemes are build/run
schemes. To install all six apps handled by the helper on a booted simulator,
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
xcodebuild build -project Luna.xcodeproj -scheme LunaCode \
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

## Luna Code and Luna Mac

Luna Code runs on iPhone or iPad. Luna Mac is a separate macOS companion that
must be running on the Mac whose source projects you want to edit or build.

1. On the Mac, install Xcode and command-line tools, clone this repository, and
   run:

   ```sh
   cd Luna
   ./script/build_and_run.sh
   ```

   This builds and opens **Luna Mac**. To compile without opening it, use
   `./script/build_and_run.sh --build-only`. By default the helper signs the
   local app ad hoc, which is sufficient for development. To preserve macOS
   Files and Folders permissions across rebuilds, sign with a certificate
   available in that Mac's Keychain:

   ```sh
   LUNA_MAC_SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' \
     ./script/build_and_run.sh
   ```

2. Build and install/run `LunaCode` on an iPhone/iPad simulator or device.
   Pair from Luna Code's Mac connection setup (or from Luna Vault, which shares
   the same Luna Mac connection). In the Luna Mac window choose **Copy
   Connection Code**, then paste it into the iOS setup flow and follow the
   fingerprint confirmation. Keep both devices on the same LAN, or sign in to
   the embedded Tailscale flow on each side when connecting across networks.
3. In Luna Code, browse Mac Files and open the containing `.xcodeproj` or
   `.xcworkspace`. Choose a scheme, then use **Prepare Code Intelligence** to
   build the Debug simulator scheme and initialize SourceKit support. The Mac
   needs Xcode and the project's dependencies resolved.
4. Edit and **Save to Mac** to persist changes to the selected project. **Build
   & Deploy to TestFlight** is optional and requires the Mac user's own App
   Store Connect authentication, registered app record, signing setup, and
   internal testing group. A simulator build is the path for trying Luna Code
   without configuring distribution signing.

The companion only serves an explicitly paired Luna client. It does not
provide hosted storage or a relay. More details: [`claudedocs/code.md`](claudedocs/code.md),
[`claudedocs/mac-connection.md`](claudedocs/mac-connection.md), and
[`claudedocs/vault-mac.md`](claudedocs/vault-mac.md).

## Credential and secret review

The shared project contains no Apple signing certificate or private key, App
Store Connect API private key, password, or Tailscale auth key. The upstream
bundle namespace, App Store URL, and Team ID were public account identifiers;
the Team ID is no longer checked into the Xcode project. Mac signing identity
is now supplied through `LUNA_MAC_SIGNING_IDENTITY` when needed. API credentials
for Luna Code's optional TestFlight operation are read from the Mac's existing
App Store Connect/`asc` setup and must be configured by that Mac's owner.

## More contributor notes

Repository-specific agent instructions are in [`AGENTS.md`](AGENTS.md).
Feature notes and manual workflows are in [`claudedocs/`](claudedocs/).
