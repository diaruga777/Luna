# Permanent util card

Every Luna card deck has one permanent utility card at carousel index zero. It
replaces the former left tray, standalone onboarding root, synthetic pasteboard
card (now DELETED outright — see `card-carousel.md`), and card-carousel empty
state.

The shared implementation is
`Luna/UtilCard/UtilCardContentViewController.swift`. There is ONE deck
(`CardCarouselHostViewController`, see `card-carousel.md`), and it constructs the
util card itself through `makeUtilCardContentController`, keeps its saves at
`cardOffset == 1`, and owns the whole `saveUtilCardURL` path — the row-into-card
transition, the ingest, and the reload that centers what the save became. A deck's
kind provider (`CardDeckProviding`) contributes cards; it never touches the
util card or the save path.

## Deck position and launch selection

- The util card is always the first/leftmost card and always appears in the mini
  carousel.
- Its chip is a UTILITY chip, not a save's: the running app's action-extension
  icon at a mini card's badge size (16pt, aspect fit), centered horizontally and
  vertically lifted off the chip's center by 1.3, with one rounded grey pill
  beneath it standing in for the card's button. Neither a favicon badge with
  skeleton body text nor a full-bleed still. The main app icon is only a bundle
  fallback if the extension artwork cannot be loaded. Both scrubber styles honour
  it, through `CardCarouselDataSource.carousel(_:prefersUtilityChipForCardAt:)`
  (answered before `prefersThumbnailChipForCardAt`) and
  `CarouselScrubberView.setUtilityChip(icon:at:)`.
- An empty store launches centered on index zero. There is no separate empty
  view or empty-card carousel.
- A non-empty store launches centered on its first save at index one. Reaching
  the util card therefore means paging left.
- New saves still take the center through the ordinary new-ID detection in
  `CardCarouselHostViewController`.

## Content shared by both states

The bottom paste row is always present. It is the real `UIPasteControl`-backed
`OnboardingPasteRow`, so Luna receives clipboard data only after the system paste
control authorizes it. A valid URL runs the surface host's normal ingest path;
invalid input resolves in the row.

The Save of the Week row is CONDITIONAL: it exists whenever
`WeeklySaveStore` holds a live signed entry for one of this app's kinds, and the
card reclaims its slot when it doesn't. Its content is the signed, CloudKit-
published weekly pick — see `claudedocs/save-of-the-week.md` for the record
schema, the signing, the 9-day/30-day age rules and the deployment steps. The
row is black with the SAME Liquid Glass rim the deck's own cards wear —
`GlassStyle.barEffect()` under `GlassStyle.glassBorderColor`, no app-palette tint
in the rim itself (`UtilURLRowGlassBorder`, shared with the recent rows and with
the save transition's shell).

**The weekly noun is a CORNER FLAG, and the flag is the one tinted thing here.**
`WeeklyRibbonView` is a small pennant flush to the row's top-left corner,
overlapping the thumbnail, filled with `LunaSurfacePalette.baseColor` — so each
app flies its own colour — and carrying the app's own noun (Save / Read /
Download / Deal), which switches to "of the month" at nine days. The subtitle
underneath is the URL host and NOTHING else: the noun used to share that line
behind a bullet and truncate the host. The row is 96pt for it
(`UtilCardLayout.weeklyRowHeight`, against a history row's 74). See
`claudedocs/save-of-the-week.md` for the flag's shape, its contrast rule and its
trait registration.

A new value REPLACING the one on screen runs a row-sized eclipse; a value
appearing or vanishing is a fade plus a reflow. In the central Luna app, which
is the only one with more than one kind, the row cycles between them every two
seconds on an interruptible spring slide — swipe to take it over, and it stays
manual until the card leaves centre or the app returns from the background.

If the weekly URL is already in the store, the row is shown dimmed with a
translucent checkmark over its thumbnail — the favicon still reads through it —
and reconciles on `.readingListChanged`.

Selecting the weekly row or a recent row calls the same full ingest path as any
other in-app save. `UtilCardSaveTransition` owns the shared handoff: the source
shell expands to the destination card while thumbnail and
labels travel independently, then the mounted destination crossfades in and the
deck centers it. The centering is the host's one ladder, where the just-made save
resolves as "a save this deck has never shown" — the top rung
(`card-carousel.md`, "A new save takes the center"). A deck keyed by a companion
store's ids (the Downloader's media rows) resolves it by URL instead; both keys
travel with the request. The growing shell is a card from its first frame: it wears the
card rim (whose radius follows the shell's own, 16 → 22) and carries Luna's own
waiting — `HorizonSpinnerView` for an article or product, `EclipseProgressBar`
for a media transfer — until the real content crossfades in.

## First-run state

`AppOnboardingStore.isCompleted == false` selects this state when the carousel
host is constructed. The card shows, top to bottom:

1. the surface-specific two-beat intro headline;
2. Save of the Week, when there is one;
3. Safari setup;
4. Shortcut/Action Button setup on capable surfaces, or share setup on the
   fallback surfaces;
5. the “or” separator, when it applies (see below);
6. the permanent paste row at the bottom.

The headline's top is `UtilCardLayout.headlineTopRatio` (0.28) of the card — a
little above the exact third the standalone onboarding root used, not up on the
card's shoulder — and the weekly row hangs below it. Both setup actions are
anchored UPWARD from the paste row (as they were on the standalone intro), not
off the headline, and the “or” sits in the seam between the last action and the
paste field.

The “or” is shown only while BOTH of these hold: the setup legs are not both
finished/skipped, and the deck holds no save of its own (the host passes
`hasSaves`). It leaves as soon as either becomes untrue — including live, on
`AppOnboardingStore.didChange` and `.readingListChanged`.

The setup actions launch the existing native Safari and Messages/setup lessons
with `AppOnboardingViewController.presentSetupReplay`. Completing or skipping a
lesson marks that setup leg handled and checks/disables its button for the
remainder of the process. Their icons are the real artwork, not generic symbols:
`safari.fill` for Safari, and for the save lesson the bundled `ShortcutsAppIcon`
(Action Button surfaces) or this app's own icon (share-sheet surfaces).

**The headline's sweep belongs to the LAUNCH.** It plays only when this
appearance is the launch's own — the deck is empty (so the util card is the
launch selection) and `AppLaunchTransition.hasFinished` is still false. Paged
back to at any other time the sentence simply stands finished
(`OnboardingIntroHeadlineView.showFinishedState()`), so nothing re-animates on a
page.

**The corona is part of this state too.** While onboarding is unanswered the
host keeps the launch splash's `EclipseCoronaView` behind the deck at the resting
centered card frame (`CardCarouselHostViewController.updateUtilCardCorona`),
fading it with the util card's centering. An incomplete first run therefore keeps
the light the splash handed it instead of losing it to the launch crossfade.

The card captures its state once per process/root construction. Finishing both
legs does not rearrange the visible card in that session. On the next app launch,
the host observes completion and constructs the completed variant.

## Completed state and recent URLs

Once setup is complete, the headline and setup buttons are absent. Save of the
Week, when there is one, moves to the top of the card — at
`UtilCardLayout.weeklyTopPadding` (12), half the padding
(`recentsTopPadding`, 24) the recent rows keep when there is no weekly pick, so
the flag is the first thing the card says. Beneath it the card adds as many
matching, unsaved recent Safari URLs as fit above the paste row; the card never
scrolls. The seam between the weekly row and the first recent
(`weeklyToRecentGap`, 25) is the widest gap on the card, and deliberately: the
pick of the week is not the first entry of the history list.

Recent rows use the same black layout as Save of the Week, minus the corner flag
(and so 74pt tall, with the title back at its 13pt top). They come from
`RecentURLMatcher.shared.matches`, so source, classification, cache, newest-first
ordering, and unsaved filtering are exactly the former recent-URL behavior:

- each Safari extension records the newest 20 raw HTTP(S) URLs in the shared App
  Group;
- evaluation runs the real ingest pipeline for the current surface;
- positive and negative verdicts are version-stamped and cached;
- saved URLs disappear on `.readingListChanged`, while deleting that save can
  reveal the cached recent again;
- if Safari is not configured and has produced no usable history, no recent rows
  appear.

## Completion and inheritance

Completion remains per app, with setup evidence shared where appropriate.
`AppOnboardingStore.isCompleted` is true when any of the following holds:

- that app has an explicit completion marker;
- central Luna's Safari and save integrations already cover a newly installed
  faceted app;
- both this app's Safari and save-setup legs have either real run evidence or a
  handled/skipped marker.

**A save answers the first run.** `AppOnboardingStore.beginOnboardingIfNeeded()`
stamps the journey's start at launch (AppDelegate, before any root reads the
state); `markCompletedIfSavedSinceOnboardingStart()` then LATCHES the completion
marker if the store holds a save newer than that stamp. So a save from any
surface — this app, a sibling, an extension, an intent, the mailbox importer —
completes onboarding, deleting that save later cannot reopen it, and a reset
(which stamps a fresh start) brings the first-run card back on the next launch
and keeps it until a NEW save arrives, however full the deck already is. The
latch runs at launch, so a save made mid-session settles the card for the next
one — the card deliberately keeps its layout for the launch that saw the save.

The ONE save it ignores is the save lesson's own. That lesson runs the real share
surface (`claudedocs/reader-onboarding.md`), so it really does append a row; it is
claimed as `AppOnboardingStore.temporarySaveIdentifier` while it exists and deleted
after each demonstration pass, and the latch excludes it — an app must not complete
its own first run on the strength of a rehearsal it played to itself. A save the
user makes through the real share sheet during that lesson is not a rehearsal and
does answer the first run.

The Safari and save handled markers are separate. This permits the buttons to
show their checked state during the launch in which setup finishes while keeping
the layout stable until relaunch. Debug `-resetOnboarding` clears completion,
handled markers, and setup run evidence.

## Validation

`UtilCardTests` pins both launch variants, the permanent paste control, the
weekly row's conditional presence (and the reflow when it is absent), the corner
flag's per-app and per-age text, the host-only subtitle beneath it, its save
callback, the bottom-up order of the
setup block, the “or” rule in all four combinations, the launch-only headline
sweep, the answered weekly row, and the save-completes-onboarding latch (older
saves and a later delete both leave it alone). `WeeklyRowHostTests` covers the
row host, its eclipse and the cycle pacer. `CarouselScrubberUtilityChipTests`
pins the strip chip's geometry. Carousel-host and price screen tests pin the
permanent index-zero offset.
