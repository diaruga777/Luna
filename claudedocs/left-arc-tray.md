# Left arc tray

The central Luna, Reader, Downloader, and Price Tracker card decks expose a
mirrored companion to the archive tray at the left edge of the first card.
Pulling right opens the wider tray and shifts the card deck; closing recenters
the taller paste row while the tray retracts.

## Row order and behavior

Rows are ordered top-to-bottom as email setup (where supported), Shortcut setup,
Safari setup, pasteboard, then up to five recent Safari matches. This makes the
pasteboard row the opening focal point, with setup above and recent links below.
Setup rows pulse until complete and own their actions directly; there is no
first-launch onboarding or generic setup-step controller.

- Email (Reader and central Luna) expands from its arc card into an inset card
  from the safe-area top to the keyboard. Its focused address field infers the
  provider live; Return and Next hand the address to `EmailAccountSetup`, which
  presents Outlook OAuth or the existing app-password credential controller as
  needed. Success shrinks/fades the expanded card, removes its row, and
  recenters the tray.
- Shortcut starts with “Save to Luna with your Action Button” and an Install
  shortcut button. Opening the bundled shortcut persists the assumed-installed
  intermediate state; the row becomes the per-app Action Button instruction
  with an Open Settings button.
- Safari says “Apply Luna in Safari” for Luna/Reader and “Save From Safari” for
  Downloader/Price Tracker, with one Open Safari button.

The Settings/Safari hops start the former onboarding guide clips directly in
Picture in Picture. PiP stops on foreground return and also through a Darwin
notification as soon as a Safari extension or App Intent records completion.

Setup completion is based on the feature actually running, not on dismissing its
guide:

- Safari is complete after the containing Safari extension's native handler has
  run.
- Shortcut is complete after any Luna App Intent has run.
- Email is complete whenever the shared email account is configured.

Reader, Downloader, and Price Tracker share Safari/Shortcut completion through
the App Group. The central Luna bundle uses independent completion keys for its
own extension and intents. Email is shown only by article-capable surfaces.

## Safari trail and matching

Every Luna Safari extension writes the newest 20 raw HTTP(S) URL strings to
`safariRecentURLHistory.v1` in the shared App Group, independently of whether the
central app is installed. Revisiting an identical raw URL moves it to the front.

On foreground, each app reads that trail and evaluates only URL strings absent
from its per-surface `recentURLChecks.<surface>.v1` cache. Positive and negative
results are cached, fallen-out URLs are pruned, and presentation always follows
the current newest-first trail. Reader matches articles/documents, Downloader
matches media, and central Luna matches every supported kind. At most five
unsaved matches are shown.

Tray rows are previews only. Selecting one runs the normal full ingest/save
path, closes the tray, centers the resulting card, and animates a snapshot into
the card deck. Long-press offers Open and Share without saving.

## Pasteboard state

The paste row probes only `UIPasteboard` detection patterns until the user
authorizes a native `UIPasteControl`, avoiding a paste permission prompt.
Tapping the Settings explanation records a per-app preference and opens the
current app's Settings page. On later tray opens that app reads automatically.
Pasteboard `changeCount` invalidates any prior result and restarts at the
appropriate empty, explicit-paste, or automatic state. Valid paste results reuse
the recent-link preview UI with a pasteboard badge; invalid values show the
failure row.
