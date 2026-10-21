# Mac-free refresh

Luna Code can keep a cached development build, renew its profiles through Apple,
sign it on the phone and reinstall it through LocalDevVPN. The Mac is needed for
initial setup and compiling new code; it does not participate in later local
refreshes. The Refresh tab remains usable without a Mac connection.

This renews free Personal Team provisioning before its seven-day expiry. It does
not remove Apple's expiry, app-slot limits, capability restrictions, certificate
limits or account checks. This is development provisioning, rather than Apple's
paid Ad Hoc distribution method. An expired Luna Code cannot run its own refresh;
recover it with an independent installer/computer if iOS did not provide runtime
before expiry.

## Initial setup

1. Run `python3 scripts/bootstrap_code_refresh.py` in the Luna checkout. It downloads
   a pinned, SHA-256-verified SideStore IDevice library and wraps the unchanged
   static archives in framework bundles to avoid Xcode header collisions with the
   existing Go bridge. The generated XCFramework is ignored. It also records this
   checkout for the local CLI/MCP launcher.
2. Build the `LunaCode` scheme. The normal build preserves Luna's existing App Group
   and shared Mac credentials. An optional free Personal Team build uses:

   ```sh
   xcodebuild -project Luna.xcodeproj -scheme LunaCode \
     -destination 'generic/platform=iOS' \
     -xcconfig Config/LunaCodePersonalTeam.xcconfig \
     DEVELOPMENT_TEAM=YOUR_TEAM -allowProvisioningUpdates build
   ```

   The flag changes only Luna Code's entitlements and connection storage. It keeps
   the bundle ID and uses sandbox storage and a non-synchronizing private connection
   Keychain. It does not migrate the existing shared connection, drafts or pairing.
   Review pairing before switching profiles; Luna Mac still uses its existing
   account approval rules. Other targets retain their existing entitlements.
   The pinned device library currently supports arm64 iOS, Simulator and Mac.
3. Install once with the user's existing native Xcode/device setup. Enable Developer
   Mode and trust the development signer when required. Do not use WebDriverAgent.
4. Install [LocalDevVPN](https://docs.sidestore.io/docs/installation/prerequisites),
   connect to Wi-Fi and enable it. The current default device endpoint is 10.7.0.1.
   Import this phone's pairing plist from an independently trusted computer in
   Refresh → Pairing File. Legacy Lockdown and modern Remote Pairing records are
   accepted; hybrid records prefer Remote Pairing. No Mac private key is exported
   automatically by Luna's remote-control channel.
5. Sign in through Refresh → Apple Account, enter an HTTPS anisette server URL and
   choose the team that signed the cached build. Apple receives the account
   credentials; the anisette server supplies sign-in data. `Sign In Once` retains
   the Apple session without retaining the password. `Sign In and Remember` also
   stores the password locally for session renewal. Two-factor/account-repair
   prompts can still require foreground sign-in.
6. Import an existing signing `.p12` and its password, or explicitly create a new
   development certificate. Existing certificates are never automatically revoked.
   Certificate limits result in an error, rather than revoking another app's key.
7. Choose Cache Luna Code for the phone client itself. For another app, complete an
   Apps-catalog build, then choose Cache for Mac-Free Refresh. This downloads the
   retained artifact in bounded chunks and verifies the complete archive digest.
   Alternatively, import an IPA. Only the currently installed bundle/version/build
   can be refreshed; cache the current build again after updating its code.
8. Use Refresh Now. For self replacement, go to the Home Screen when prompted and
   reopen Luna Code after installation. Automatic Refresh is opt-in for each app.

No Apple credentials, `.p12`, pairing secrets or ADI material enter the catalog,
Mac RPCs, preferences, source tree or diagnostic exports. They are stored in the
phone's Keychain with `AfterFirstUnlockThisDeviceOnly`, without synchronization.
Sign Out removes the Apple session, optional password and signing certificate;
it preserves the independently imported phone pairing record.

## Implementation

- `LunaCodeCore/CodeLocalRefresh.swift` owns durable public status, confirmation
  policy and app-private cache locations. Cached app sources are separate from
  signing workspaces. Their tree digest is checked before every refresh.
- `LunaCodeRefreshKit` owns Apple account setup, fresh provisioning, SideSign signing,
  device installation, readback, the UIKit Refresh screen and BGProcessing tasks.
- The same team and bundle IDs must survive refresh. Profiles cover the phone,
  matching signing certificate, main app and every extension. Existing keychain,
  App Group, iCloud and associated-domain entitlements must remain available.
  Builds containing Watch apps are rejected by this initial path.
- Imported ZIP entries are validated before any extraction: traversal, symlinks,
  duplicate names, multiple apps and excessive entry sizes are rejected.
- The installation journal is written before handoff. A lost response or killed
  self update remains unconfirmed until installed version/build and all intended
  new profile UUIDs/expirations are read back. Compilation, signing and upload do
  not count as renewal. Clear Pending Attempt is an explicit recovery action,
  available only after 15 minutes; it preserves the cached build.
- Automatic refresh becomes due 48 hours before expiry and backs off for an hour
  after an attempt. New background requests are eligible after six hours. iOS
  controls when they actually run. Other cached apps are processed before Luna
  Code; one failure does not stop attempts for the others. Expiration cancels work.
- Existing Mac builds, TestFlight jobs, schedules and authenticated reverse streams
  remain available. Local refresh does not depend on those reverse streams and can
  replace Luna Code itself through its independent local installation connection.

## Dependencies and verification

SideSign is pinned to `752d1ef602aa792a432ffa1e71646dc1ecf7363c`.
The vendored gateway/common source subset is from SideStore/minimuxer
`12be70dc2627307a16bfd2dc7a009080d5bec909`; its AGPL-3.0 license and local changes
are preserved in `LunaCodeRefreshKit/Vendor/DeviceGateway/`. Transitive source and
binary revisions are recorded in Package.resolved. Upstream licensing remains
applicable to distribution; see `LunaCodeRefreshKit/THIRD_PARTY_NOTICES.md`.

Verified on 2026-10-21: Code policy/catalog/export unit tests, archive and pairing
validation tests, CLI/plugin tests, Mac companion tests, Apple adapter race tests,
Simulator compilation and the real unpaired Refresh setup/cancel flow. No Apple
account was signed in and no physical device was accessed. Initial installation,
profile renewal, self replacement, extension renewal, account limits, session
reauthentication and actual background scheduling need acceptance with the intended
Apple account, iOS version, pairing file and LocalDevVPN setup. These are not
proven by Simulator or synthetic tests.
