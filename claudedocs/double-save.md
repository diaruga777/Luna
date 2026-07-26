# Double save (Reader, Action Button only)

Saving the exact same URL twice within 7 seconds through Luna Reader's Action
Button intents sends the already-saved article to Kindle when Kindle is
configured. If Kindle is not configured, the second save does nothing. This is
fixed behavior: there is no double-save settings section and double save never
sends to a contact.

`SaveIntent` also detects a repeated screenshot by digest. A visually similar
screenshot inside the same seven-second window re-runs the previous save without
another model call, so it reaches the same Kindle-or-no-op decision.

No other save surface uses this regime. Share/action/Safari extensions, paste,
manual add, mail import, Luna Downloader, and Luna Price Tracker keep normal
save semantics.

## Flow

The Reader Action Button intents pass a non-nil
`doubleSaveActionSurface` through `IntentIngestHelper` to
`ReadingListIngestor.handleSavePress`. The ingestor arms
`SavePressPolicy.IntentAction.sendToKindle` only when the Kindle destination is
configured. A repeat within `intentDoublePressWindow` (7 seconds) then becomes
`.sendToEreaders([kindle])`, retaining the 24-hour resend cooldown. A platform
item or unconfigured Kindle is ignored.

The older 12-second in-app regime remains for a configured ereader destination
whose capture-source mode is `.doubleSave`; it also only sends to that ereader.

Legacy `DoubleSaveActionStore` values may remain in an existing App Group, but
the active resolver and Settings UI no longer read them. Pending contact prompts
are not consumed on foreground.

## Tests

`SavePressPolicyTests` covers the seven-second boundary, Kindle cooldown and
platform-item exclusion, plus the older in-app ereader regime.
