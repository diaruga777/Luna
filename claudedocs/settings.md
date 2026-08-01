# Settings

The top-level Settings menu is composed per app by `KindWiring.settingsCategories()`
and finished by `SettingsViewController`.

## Shared navigation

- Diagnostics has no visible row. Five taps in blank space on the top-level
  Settings table pushes `DiagnosticsViewController`; taps on rows and controls
  do not count.
- Shortcut & Safari contains Safari suggestion visibility, on-screen URL
  handling, the Double Save action, and shortcut actions. Media download size is
  automatic, so there is no Download in Background setting. Double Save appears
  only in Luna and Reader (see double-save.md) and defaults to Nothing.
- Appearance contains only the theme choice. Reader eclipse navigation is always
  enabled unless the system Reduce Motion accessibility setting is on.

## Reader and Luna

- Reader contains speed-reader/typography/highlight controls followed by the
  Preload Links section (Wi-Fi Only and Preload Depth). Reading time and progress
  remain visible on article rows and have no settings.
- Audio contains autoplay, listening cleanup, enhanced-voice status, and Install
  Enhanced Voices. There is no child Voice page.
- Email groups the connected sharing account, mail import/senders, and subject
  filters. Its address field uses the same rounded envelope-card treatment as
  the left-tray setup.
- Kindle is a separate top-level page. Until email is configured, its row is
  dimmed; tapping it shows "Set up email first" with Not Now and OK. OK opens
  Email and focuses the address field. The Kindle page contains forwarding
  settings, address, and test send.
- Contacts remains its own address-book page.

Action Button double save has no settings. On Reader it sends to configured
Kindle or does nothing; it cannot send to a contact.

## Media apps

Luna and Luna Downloader show the same Downloads page:

- Download Automatically: Never, Always, or On Wi-Fi Only.
- Storage: Save to Photos for every completed download, or keep all downloads in
  Luna with one deletion age.

There are no per-platform Photos choices. App Intent media downloads also have no
manual background switch: known files up to 100 MiB finish inline; larger or
unknown files move to the durable background engine.
