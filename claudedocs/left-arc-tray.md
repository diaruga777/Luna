# Left arc tray

The central Luna, Reader, and Downloader card decks expose a mirrored companion
to the archive tray at the left edge of the first card. Price Tracker is
deliberately deferred. Pulling right opens the tray and shifts the card deck;
closing recenters the taller paste row while the tray retracts.

## Row order and behavior

Rows are ordered top-to-bottom as email setup (where supported), Shortcut setup,
Safari setup, pasteboard, then up to five recent Safari matches. This makes the
pasteboard row the opening focal point, with setup above and recent links below.
Setup rows reuse the focused visual language and copy from the deleted
first-launch onboarding, but each is now an independent modal destination.

Setup completion is based on the feature actually running, not on dismissing its
guide:

- Safari is complete after the containing Safari extension's native handler has
  run.
- Shortcut is complete after any Luna App Intent has run.
- Email is complete whenever the shared email account is configured.

Reader and Downloader share Safari/Shortcut completion through the App Group.
The central Luna bundle uses independent completion keys for its own extension
and intents. Email is shown only by article-capable surfaces.

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
