# Settings

The top-level Settings menu is composed per app by `KindWiring.settingsCategories()`
and finished by `SettingsViewController`.

## Shared navigation

- Every settings screen is a `NavHeaderTableController`, and on a wide container
  that base holds the rows in a readable column
  (`LunaLayout.contentHorizontalInset`) instead of stretching a toggle a thousand
  points from its label. `.insetGrouped` derives each section's inset from the
  table's own layout margins, so widening those narrows the whole column —
  backgrounds, separators and content together. The safe-area contribution is
  switched off first, or a landscape iPad's own insets would be added on top and
  the column would drift off centre. The header BAR is deliberately not inset:
  bar buttons belong at the screen's edges, which is where every iPad navigation
  bar puts them.
- Diagnostics has no visible row. Five taps in blank space on the top-level
  Settings table pushes `DiagnosticsViewController`; taps on rows and controls
  do not count. That screen also holds the Save of the Week signing key entry
  (`save-of-the-week.md`).
- Save of the Week appears as a top-level category ONLY on a device holding the
  curator's signing key. It is the proposal inbox: promote or delete, both of
  which retire the proposal record.
- Shortcut & Safari contains Safari suggestion visibility, on-screen URL
  handling, Double Save Articles, and shortcut actions. Media download size is
  automatic, so there is no Download in Background setting. Double Save Articles appears
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
  the util-card setup.
- Kindle is a separate top-level page. Until email is configured, its row is
  dimmed; tapping it shows "Set up email first" with Not Now and OK. OK opens
  Email and focuses the address field. The Kindle page contains forwarding
  settings, address, and test send.
- Contacts remains its own address-book page.

Double Save Articles offers Nothing, Send to Kindle, and View immediately. It
cannot send to a contact and never applies to non-article items.

## Media apps

Luna and Luna Downloader show the same Downloads page:

- Download Automatically: Never, Always, or On Wi-Fi Only.
- Storage: Save to Photos for every completed download, or keep all downloads in
  Luna with one deletion age.

There are no per-platform Photos choices. App Intent media downloads also have no
manual background switch: known files up to 100 MiB finish inline; larger or
unknown files move to the durable background engine.
