# Left arc tray

The central Luna, Reader, Downloader, and Price Tracker card decks expose a
mirrored companion to the archive tray at the left edge of the first card.
Pulling right opens the wider tray and shifts the card deck; closing recenters
the taller paste row while the tray retracts.

## Row order and behavior

Rows are ordered top-to-bottom as email setup (where supported), Shortcut setup,
Safari setup, pasteboard, then up to five recent Safari matches. This makes the
pasteboard row the opening focal point, with setup above and recent links below.
When the tray closes on the deck's leftmost card, the narrow physical clipboard
slides to the trailing edge of its wider transparent row, so the tray's 26-point
peek contains clipboard artwork. It returns to its original leading position as
the tray expands.
Setup rows pulse until complete and own their actions directly; there is no
generic tray-level setup-step controller. All four apps also introduce the same
Safari/Shortcut/Action Button actions during their surface-specific first-run
experience (see `reader-onboarding.md`).
Every tray card uses a barely off-black surface. Setup rows contain no leading
glyph: their copy and standard Liquid Glass button are centered as a single
stack. Arc positioning preserves each row's vertical center and limits rotation,
so transformed cards retain visible separation rather than overlapping.

- Email (Reader and central Luna) expands from its arc card into an inset card
  from the safe-area top to the keyboard. Its focused address field infers the
  provider live; Return and Next hand the address to `EmailAccountSetup`, which
  presents Outlook OAuth or the existing app-password credential controller as
  needed. Success shrinks/fades the expanded card, removes its row, and
  recenters the tray.
  If a previously connected provider rejects its saved credential, the row is
  revived as an orange **Email login needs attention** card with provider-path
  detail and a **Reconnect in Settings** action. Tapping either the card or its
  action opens Settings → Email directly; it does not show the new-account
  address card over an account that still exists. Reconnecting removes the row
  again. The route is installed through
  `LeftTrayController.emailRecoveryLauncher` by the Luna/Reader `KindWiring`
  variants, so the shared tray source still compiles in Downloader and Price
  Tracker without naming their unlinked Email settings controller.
- Shortcut opens the one-click-save Messages walkthrough. It disappears when
  ANY Luna app has recorded a real App Intent run, or when this app's own
  onboarding has already handled/skipped the walkthrough.
- Safari says “Apply Luna in Safari” for Luna/Reader and “Save From Safari” for
  Downloader/Price Tracker, with one Open Safari button.

The Settings/Safari hops start the former onboarding guide clips directly in
Picture in Picture. PiP stops on foreground return and also through a Darwin
notification as soon as a Safari extension or App Intent records completion.

Setup completion is based on the feature actually running, not on dismissing its
guide:

- Safari is complete after the containing Safari extension's native handler has
  run.
- Shortcut intent evidence and installer-press evidence are stored per app.
  The tray considers Shortcut complete after either Action Button intent has
  run in any app; the
  press alone is not completion because iOS cannot report whether import was
  finished.
- Email is complete whenever the shared email account is configured and ready.
  A persisted `EmailAccountStore.authenticationIssue` makes it incomplete until
  the user reconnects or signs out.

Reader, Downloader, and Price Tracker retain the historical shared Safari key.
Shortcut intent runs now use exact per-app keys (the old faceted aggregate is a
read-only migration fallback). Central Luna's Safari/intent evidence also marks
the corresponding buttons done in subsequently installed faceted apps. Email
is shown only by article-capable surfaces.

## Safari trail and matching

Every Luna Safari extension writes the newest 20 raw HTTP(S) URL strings to
`safariRecentURLHistory.v1` in the shared App Group, independently of whether the
central app is installed. Revisiting an identical raw URL moves it to the front.

On foreground, each app reads that trail and evaluates only URL strings absent
from its per-surface `recentURLChecks.<surface>.v1` cache. Positive and negative
results are cached, fallen-out URLs are pruned, and presentation always follows
the current newest-first trail.

**The cache is stamped with `AppConfig.appVersion` and discarded when that
changes.** Every entry is a verdict DERIVED by the pipeline, and because only
URLs *absent* from the cache are evaluated, a pipeline change would otherwise
never reach the ones already in it — a Google search page kept its row after the
classifier learned to reject search-results URLs, because the tray was replaying
a verdict recorded by an older build. Tying the cache to the version (short
version *and* build, the same key `SaveFailureRecord.aiAttemptVersion` uses for
the same reasoning) makes every future classification change self-healing, with
no bump to remember and at most 20 re-checks per install. `publish` additionally
re-applies the URL-only half of the veto (`RecentURLMatcher.isObviouslyNonContent`)
to each cached match on the way to the screen — free, since it reads no HTML, and
it closes the same window inside a single build. Pinned by
`RecentURLMatcherTests`. Reader matches articles/documents, Downloader
matches media, and central Luna matches every supported kind. At most five
unsaved matches are shown.

The unsaved filter is republished on every `.readingListChanged`, using the
already-cached verdicts before any asynchronous classification work. Therefore
tapping a recent removes it in the same save event, and deleting that save
reveals the cached recent again immediately; neither direction waits for a
foreground cycle or app relaunch.

The trail itself is unfiltered — `background.js` reports every http(s) tab,
whether or not the page earned a Luna pill — so `RecentURLMatcher.evaluate`'s
real `IngestPipeline.processResolved` call is the ONLY filter between "a page you
visited" and "a row". That is why the tray was the first place the pipeline's
missing index veto showed: the pipeline answered `.needsArchive` for any titled
page and `.article` for any index that extracted past the readable threshold, so
homepages and search results queued up as things to read. Both now come back
`.failed(.notContent)`, which the matcher already drops — see `ListingPage` in
`claudedocs/url-pipeline.md`. The tray inherits the fix; it holds no
classification of its own, and deliberately shouldn't.

Tray rows are previews only. Selecting one runs the normal full ingest/save
path, closes the tray, and centers the resulting card. The recent's empty card
shell translates and expands to the carousel frame while real UIKit copies of
its thumbnail and title move independently into the destination's usual
favicon/title-header geometry; they are never scaled to the full card height.
Once the saved card mounts, its contents replace that temporary header in a
short crossfade. The destination stays hidden until that handoff, avoiding a
card pop followed by a translucent ghost zoom. Long-press offers Open and Share
without saving.

## Pasteboard state

The paste row probes only `UIPasteboard` detection patterns until the user
authorizes a native `UIPasteControl`, avoiding a paste permission prompt.
Tapping the Settings explanation records a per-app preference and opens the
current app's Settings page. On later tray opens that app reads automatically.
Pasteboard `changeCount` invalidates any prior result and restarts at the
appropriate empty, explicit-paste, or automatic state. Valid paste results reuse
the recent-link preview UI with a pasteboard badge; invalid values show the
failure row.
