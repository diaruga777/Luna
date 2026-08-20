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

The Luna team row is CONDITIONAL: it exists whenever
`WeeklySaveStore` holds a signed entry for one of this app's kinds, and the card
reclaims its slot when it doesn't. Its content is the signed, CloudKit-
published Luna team pick — see `claudedocs/save-of-the-week.md` for the record
schema, the signing, and the deployment steps.

**The Luna team row is dressed apart from the recent rows.** Both are the same black
`UtilURLRow` under the same Liquid Glass recipe (`GlassStyle.barEffect()` in
`UtilURLRowGlassBorder`), but the Luna team pick is Luna's own recommendation
and carries the app's colour, three ways at once: a palette wash over the black
(`UtilURLRow.weeklyWashAlpha`), the rim's stroke replaced by the palette
(`UtilURLRowGlassBorder.rimTint` at `weeklyRimAlpha` — comparable in weight to
the neutral white-at-0.14 rim, not a saturated outline), and the corner flag. A
recent is raw Safari history and stays neutral in all three. The save
transition's growing shell takes the weekly row's flattened fill and its rim
tint (`UtilCardSaveTransitionArtwork` carries both), so a weekly save opens from
exactly the row that was tapped instead of flicking to neutral on its first
frame.

**The Luna team attribution is a CORNER FLAG, not a phrase in the subtitle.**
`WeeklyRibbonView` is a small tab flush to the row's top-left corner, 20pt tall
so it clears the thumbnail instead of crossing it, closed by a single arc on its
trailing edge, and filled with the app's colour dimmed into the row's own black —
so each app still flies its own without outshining the pick it labels. It carries
the single label "From the Luna team" for every app and every entry age. The
subtitle underneath is the URL host and NOTHING else: the attribution used to
share that line behind a bullet and truncate the host. The row is 96pt for
it (`UtilCardLayout.weeklyRowHeight`, against a history row's 74). See
`claudedocs/save-of-the-week.md` for the flag's shape, its dimming and contrast
rule, and its trait registration.

A new value REPLACING the one on screen runs a row-sized eclipse; a value
appearing or vanishing is a fade plus a reflow — and an appearing row fades in
IN PLACE: its host is laid out before the animation starts, so only the card's
other elements animate their reflow while the row itself comes up at full size
rather than growing into its slot. In the central Luna app, which
is the only one with more than one kind, the row cycles between them every four
seconds on an interruptible spring slide — swipe to take it over, and it stays
manual until the card leaves centre or the app returns from the background. A
missing central kind still receives its turn, but its row is fully transparent:
there is no blank card shell, rim, or hit target. Each cycling kind uses its
own softened app tint (Reader blue, Downloader orange, Price Tracker green),
even while running inside central Luna.

If the weekly URL is already in the store, the row is shown dimmed with a
translucent checkmark over its thumbnail — the favicon still reads through it —
and reconciles on `.savesChanged`.

A row's thumbnail fills its square for a photograph and FITS, over the subtle
fill `CarouselSourceBadgeView` uses, for anything markedly non-square: the site
marks `FaviconFetcher` returns include wordmark logos (700×197 is a real one),
and filling one crops it to three letters.

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
waiting — `HorizonSpinnerView` for an article or product, `MoonHorizonProgressBar`
for a media transfer — until the real content crossfades in.

**Only a `UtilURLRow` gets that handoff.** The transition is built from artwork
the source hands over (`UtilCardSaveTransitionArtworkProviding`: a kind, a fill,
a thumbnail, a title), and a source that has none does not get a grow at all.
There is deliberately no flat-snapshot fallback — the one source that ever took
that path, the 40pt paste row, was stretched some fifteen times its own height
and filled the card with a smeared copy of itself, placeholder text included
(a snapshot taken `afterScreenUpdates: false` predates the pasted value
landing). A paste says what it is doing where it stands: the pasted URL in the
field, a spinner ahead of it, then the mark.

## The setup block

The setup buttons belong to BOTH states, not just the first run: the two system
lessons are first-run business, but the email nudge only becomes due once there
are saves — by which time this is the completed card.

`UtilCardSetupOffer` decides what is on screen. The candidates, in priority
order — which is also the order they read top to bottom — are:

| Button | Offered while |
|---|---|
| Safari (`safari.fill`) | not retired (see below) |
| Save / Action Button shortcut (bundled `ShortcutsAppIcon`) | this device can run the lesson AND it is not retired |
| Email (`envelope.fill`, “Read your newsletters in Luna”) | `LunaApp.sharesByEmail`, no account connected, and the ask is earned |

**At most TWO.** A third leaves the card no room for the weekly row and the
recent URLs, and email — a nudge, not a requirement — is the one that loses.
So it effectively appears only once one of the other two has stopped asking.
Every button keeps its icon at a fixed leading inset; the smaller, single-line
label begins immediately after it, so changing labels in central Luna never
shifts either icon.

**Full-width is a CENTRAL-LUNA-ONLY trait, and only for Safari/shortcut.** In
central Luna, `UtilCardSetupTextCycler` advances the Safari and shortcut
buttons' labels through every sibling app's own phrasing as the weekly row
cycles, so those two buttons stay stretched edge to edge — the room a longer
sibling phrase might need.

**The cycling belongs to central Luna, not to its first run.** Both states keep
these buttons, and both keep them full-width, so both keep the phrases arriving:
the cycler is built for `app == .luna` alone. It was once built only while the
card `showsOnboarding`, and since a save from any surface latches completion, the
first save froze the labels from the next launch on — edge-to-edge buttons sized
for movement that had stopped.

**Exactly one clock advances the labels, and the weekly row gets first refusal**
(`UtilCardContentViewController.updateSetupLabelClock`, the single decision
point — called at the intro hand-off, on a presence change, on a retirement, and
as the card takes or leaves centre). A row on screen is the better clock, since
its turn and the labels are then the same app's by construction. But a card with
no live pick has no row at all: then the cycler keeps its OWN timer, which is
also what carries the opening cadence before the row appears. The hand-off at the
end of the intro used to stop that timer unconditionally and hand over to a row
that, with an empty `WeeklySaveStore`, never came — so a first run without a live
pick moved both labels exactly once and then stood still for good. Nothing runs
while the card is off centre, or while no cycling button is on the card.

**The labels are the ROW's app, and they hold no counter of their own.**
`WeeklySaveRowHost.onCycle` reports the KIND the row is arriving at — from
`settle`, the one place that knows the destination, which an auto-advance and a
committed swipe both reach — and the card puts `kind.owningApp`'s phrasing on
both labels. The cycler used to count from its own zero on each tick while the
row moved on to the slot AFTER the one that tick found, so the pair drifted a
turn apart (the Price Tracker's phrasing under the Reader's pick) and a manual
swipe desynced them too. Before the first turn the labels still carry central
Luna's own line; a card leaving centre resets to it.

**A cycling label must never be laid out mid-slide.** UIKit positions a
configuration button's title by ASSIGNING ITS FRAME, and assigning a frame to a
transformed view makes UIKit solve for the centre that puts the *transformed*
view there — so every layout pass landing inside a 0.55s slide baked the offset
into the label's centre and walked the title toward the trailing edge one turn at
a time until it read as right-aligned. `UtilCardSetupActionButton` (the class all
three setup buttons use) lifts the transform off for the duration of
`layoutSubviews` and puts it back after, so the slide is a pure overlay on a
label UIKit always lays out at rest. `WeeklySaveRowHost.layoutSubviews` answers
the same conflict the other way, by skipping rows it is animating — an option
only open to a view that assigns those frames itself.

Every other app's label never changes, so stretching
it edge to edge just reads as too wide: `UtilCardContentViewController
.compactSetupButtonWidth` sizes the Safari and shortcut buttons to their own
content and centers them in the block on those three apps, while leaving the
vertical stacking (order, gaps, which slot a lost lesson gives up) untouched.
Email keeps the full-width treatment everywhere — it never cycles, in central
Luna or anywhere else.

**There is no share-sheet save lesson.** Luna's only save lesson is the Action
Button shortcut; a device that cannot run it (`OnboardingSaveSetupMode
.unavailable`) is offered nothing in that slot, and its save leg counts as
finished because nothing is owed. The block stacks UP from the paste row, so an
absent lesson is not a gap: Safari simply takes the bottom slot.

**Email is earned by three saves, or by two days with the first one** —
whichever comes first (`UtilCardSetupOffer.emailIsEarned`, counting saves from
any surface). It arrives live: `.savesChanged`, a foreground, and
`EmailAccountStore.accountChanged` all reflow the block, so the third save brings
the button in and connecting an account takes it away. Tapping it runs
`UtilCardContentViewController.emailSetupLauncher` — installed by the `KindWiring`
variants of the two email apps, because `EmailAndKindleSettingsScreen` is not
compiled into the other two — which pushes Settings → Email with the address
field focused (`claudedocs/email-login.md`).

### Where downloads are stored

Above the lessons, and outside their two-button budget, the two apps that
download media carry one more line: **“Store downloads *in Luna* / *in
Photos*”**. It is not a setup lesson and does not wait for the first run to be
over — it belongs to BOTH variants, always tops the block, and while it is
present the completed card shows **no recent URLs** (its options open over the
room they would take).

It makes the safe default explicit: fresh installs store downloads **in Luna**
and do not ask for Photos access unless the person selects it.

- **A subtle selector outline, not a fourth action button.** The sentence and
  current option are horizontally centred as one control; inside the pill, the
  *app icon + “in Luna”/“in Photos” + indicator* group is centred as one unit.
  The Luna icon has a subtle squircle rim and breathing room around its moon;
  the Photos glyph deliberately has no rim. Its up/down carets sit directly
  after the label. The pill is always sized for the longer *in Photos* option,
  so neither it nor the sentence shifts when the selection changes.
  The icons are the real artwork at the text's own height — the running app's
  own icon (`LunaAppIconImage`) and the Photos pinwheel Luna draws
  (`PhotosAppGlyph`; a sandboxed app cannot read another app's icon).
- **The options open IN PLACE**, over whatever the card has above them: the
  panel lands with the SELECTED option exactly on the collapsed selector, so the
  word being read does not move and the alternative appears beside it. Its 58pt
  rows are visibly spaced for clean tap targets. The panel
  and its tap-to-dismiss catcher are hosted by the CARD, not by the row — a
  row-sized view cannot cover the rows and buttons around it.
- **Photos is a REQUEST, not a write.** Choosing it asks for read/write access
  first (the superset both download paths need, as
  `MediaPhotosPreflight` does) and saves the setting only if the answer is yes.
  A refusal reverts the line — and the setting — to *in Luna*. iOS shows that
  prompt once, so a SECOND attempt cannot ask again: it opens Luna's own page in
  system Settings (`UIApplication.openSettingsURLString`) instead of failing
  silently.
- **“In Luna” means the inline age**, `MediaStorageSettings.inlineRetention` (2
  weeks) — deliberately shorter than the Settings screen's `defaultRetention`
  (1 month), because this choice is made before there are any downloads to judge
  by. If the user already has an age, the row only moves them off Photos and
  leaves that age alone.
- **Answered once, gone next launch.** `MediaStorageSettings.hasExplicitChoice`
  is the marker, and every user-facing control writes through
  `MediaStorageSettings.choose` — so answering in Settings → Downloads retires
  the row too, and a refused Photos request counts as an answer. The card reads
  the marker ONCE at construction, like `showsOnboarding`: the row stays for the
  rest of the launch that answered it rather than vanishing under the tap.
- **Per-app by linkage, like every other kind-specific hook.** The card names no
  media symbol; `DownloadStorageChoice.installed` (LunaModels) is the seam,
  `MediaUtilCardStorageChoice.install()` fills it from
  `KindWiring+Luna`/`KindWiring+Downloader`, and Reader and Price Tracker — which
  link no media module — leave it nil and never build the row.

**A finished button is retired the next time the app leaves the foreground.**
Completing a lesson checks and disables its button for the rest of that session;
`AppOnboardingStore.retireCompletedSetupButtons()`, called from AppDelegate on
`applicationDidEnterBackground` and again at launch, then takes it off the card
for good — which is what frees a slot for email. SKIPPING is not finishing: a
skipped lesson keeps its button (the offer stays open) and keeps outranking
email. The outcome is persisted per leg, so the distinction survives relaunches.

## First-run state

`AppOnboardingStore.isCompleted == false` selects this state when the carousel
host is constructed. The card shows, top to bottom:

1. the surface-specific two-beat intro headline — ONE line in every app, its
   second beat animating the difference between two states of the same sentence
   (`claudedocs/reader-onboarding.md`, "Surface headlines");
2. Save of the Week, when there is one;
3. the setup block (above);
4. the “or” separator, when it applies (see below);
5. the permanent paste row at the bottom.

The headline's top is `UtilCardLayout.headlineTopRatio` (0.28) of the card — a
little above the exact third the standalone onboarding root used, not up on the
card's shoulder — and the weekly row hangs below it. It is that TOP that is
fixed, not the headline's height: the Downloader's headline is two lines
(`claudedocs/reader-onboarding.md`, "Surface headlines"), so it is twice as tall
from the moment it is built and the weekly row hangs that much lower. The second
line's room is reserved before it has anything on it, so the line above never
moves when the second beat brings it in. The setup actions are
anchored UPWARD from the paste row (as they were on the standalone intro), not
off the headline, and the “or” sits in the seam between the last action and the
paste field.

The “or” is shown only while BOTH of these hold: the setup legs are not both
finished/skipped, and the deck holds no save of its own (the host passes
`hasSaves`). It leaves as soon as either becomes untrue — including live, on
`AppOnboardingStore.didChange` and `.savesChanged`.

The two lesson buttons launch the existing native Safari and Messages lessons
with `AppOnboardingViewController.presentSetupReplay`. Completing or skipping a
lesson marks that setup leg handled and checks/disables its button for the
remainder of the process. Their icons are the real artwork, not generic symbols:
`safari.fill` for Safari and the bundled `ShortcutsAppIcon` for the save lesson.

**The headline's sweep belongs to the LAUNCH.** It plays only when this
appearance is the launch's own — the deck is empty (so the util card is the
launch selection) and `AppLaunchTransition.hasFinished` is still false. Paged
back to at any other time the sentence simply stands finished
(`OnboardingIntroHeadlineView.showFinishedState()`), so nothing re-animates on a
page — including a two-line headline, whose second line is already there rather
than waiting to arrive.

**On that launch, the headline speaks first.** The setup actions, “or”, paste
row, and storage chooser wait at alpha 0 until the second beat's bloom has
finished, then fade in together, in place (0.38s ease-out, 0.16s after the
sweep's completion — the standalone intro card's own beat). Central Luna starts
its setup-label cycle as those buttons arrive, rather than waiting behind the
weekly row. The weekly row waits separately: after the three-second hold, its
intro text fades out and the row fades in at the next label-cycle boundary, so
it never appears midway through a title slide. The other apps have no changing
labels, so their intro text fades out and weekly row fades in as soon as that
hold ends. That crossfade is a short 0.24s ease-in-out beat in every app. A weekly value arriving during either wait remains hidden until that
handoff; only then can central Luna's weekly row take over the label cadence.
Reduce Motion makes each reveal instant. Any appearance that does NOT animate the sweep (paged back to,
onboarding already complete) shows everything immediately.

**The corona is part of this state too.** While onboarding is unanswered the
host keeps the launch splash's `EclipseCoronaView` behind the deck at the resting
centered card frame (`CardCarouselHostViewController.updateUtilCardCorona`),
fading it with the util card's centering. An incomplete first run therefore keeps
the light the splash handed it instead of losing it to the launch crossfade.

The card captures its state once per process/root construction. Finishing both
legs does not rearrange the visible card in that session. On the next app launch,
the host observes completion and constructs the completed variant.

## Completed state and recent URLs

Once setup is complete the headline is absent, and so are the lesson buttons as
soon as they are retired. **Save of the Week sits at its own seat above the
headline's**: `UtilCardLayout.weeklyTopRatio` (0.14 of the card, half
`headlineTopRatio`), so the flag is the first thing the card says. Beneath it the
card adds as many matching, unsaved recent Safari URLs as fit above whatever the
setup block leaves (the paste row, when the block is empty — the email nudge can
still hold a slot here); the card never scrolls. The seam between the weekly row
and the recents (`weeklyToRecentsGap`, 65) is by far the widest gap on the card,
deliberately: that distance is what groups the history rows together and leaves
the weekly row on its own. With no live pick there is no seat to keep and the
history block starts at `recentsTop` instead, taking the whole card (one row more
fits).

Recent rows use the same black layout as Save of the Week but the neutral Liquid
Glass rim, no palette wash, no corner flag (and so 74pt tall, with the title back
at its 13pt top), and only the URL host as the subtitle. They come from
`RecentURLMatcher.shared.matches`, so source, classification, cache, newest-first
ordering, and unsaved filtering are exactly the former recent-URL behavior:

- each Safari extension deduplicates before persisting the newest 20 raw HTTP(S)
  URLs in the shared App Group; revisiting a URL promotes its sole copy to front;
- evaluation runs the real ingest pipeline for the current surface;
- positive and negative verdicts are version-stamped and cached;
- saved URLs disappear on `.savesChanged`, while deleting that save can
  reveal the cached recent again;
- if Safari is not configured and has produced no usable history, no recent rows
  appear.

**Both caps apply to the collapsed list, never to the raw one.** A page the user
visited twice must not take two rows or two of the twenty trail slots, so
duplicates are removed BEFORE either count: `SafariRecentHistoryStore.URLs`
collapses repeated raw strings before its `limit` of 20, and
`RecentURLMatcher.deduplicated` collapses previews before `publish`'s five. The
first occurrence wins in both, and the trail is newest-first, so the survivor is
the most recent visit. Previews compare by `RecentURLMatcher.identityKey`, which
takes the fragment and the tracking params off through `URLCanonicalizer.strip`
— THE place that decision lives, so a row can never disagree with what the store
considers one page — and adds only the three cosmetic differences a raw Safari
trail carries and a canonical URL does not: the scheme, a `www.`, a trailing
slash, plus case-folding the host. Everything the canonicaliser kept is kept: a
real query is what separates one video or product from the next. The saved-URL
filter uses the same key, so a save stored in a cosmetically different form still
clears its row.

## Completion and inheritance

Completion remains per app, with setup evidence shared where appropriate.
`AppOnboardingStore.isCompleted` is true when any of the following holds:

- that app has an explicit completion marker;
- central Luna's Safari and save integrations already cover a newly installed
  faceted app;
- both this app's Safari and save-setup legs have either real run evidence or a
  handled/skipped marker — and on a device with no Action Button the save leg is
  finished by definition, so Safari alone completes the first run there.

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

The Safari and save handled markers are separate, and each records HOW it was
handled (completed or skipped) plus whether its button has been retired. This
permits the buttons to show their checked state during the launch in which setup
finishes while keeping the layout stable until relaunch. Debug `-resetOnboarding`
clears completion, all six per-leg markers, and setup run evidence.

## Validation

`UtilCardTests` pins both launch variants, the permanent paste control, the
weekly row's conditional presence (and the reflow when it is absent), the corner
flag's per-app and per-age text, the host-only subtitle beneath it, its save
callback, the bottom-up order of the
setup block, the “or” rule in all four combinations, the launch-only headline
sweep, the headline-speaks-first hold (elements at alpha 0 on the animating
launch, visible immediately on any other appearance, and a mid-sweep weekly
arrival claiming its slot at alpha 0), the answered weekly row, the completed
card's horizon (the weekly row on the headline's ratio, a wider seam above the
recents than between them, and the recents reclaiming the top without a pick),
the weekly row's dressing apart from a history row (rim tint, fill, subtitle
colour, all read back through the save-transition artwork), the corner flag's
geometry (clear of the artwork, one arc on its trailing edge, every app's fill
dim enough to letter in white), and the save-completes-onboarding latch (older
saves and a later delete both leave it alone). It also pins the setup block's
offers: Safari taking the bottom slot when there is no save lesson, the email
nudge's two earning conditions, its absence while both lessons are still offered
and in the apps that connect no account, the slot a retired lesson gives up, a
skipped lesson keeping its button, and the third save bringing email in live. Its
recents come through the card's injected `recentMatches`, so the block's geometry
is assertable without a real Safari trail. The storage line is pinned there too
— that it tops the block, belongs to both variants, stands the recents down, is
absent in an app that downloads nothing or once the question is answered, opens
both options with the selected one in place, reverts on a refusal, and opens
system Settings on the second attempt — through an injected
`DownloadStorageChoosing`; the real one's own behaviour (the permission request,
the revert, the inline age, the answered marker) is in
`AutoDownloadSettingsTests`.
The cycling labels are pinned there too, driving the row's real slide: each turn
carries the phrasing of the app whose pick the row arrives with, and the label
holds its leading position across turns even when a reflow lands mid-slide.
`WeeklyRowHostTests` covers the
row host, its eclipse and the cycle pacer. `CarouselScrubberUtilityChipTests`
pins the strip chip's geometry. Carousel-host and price screen tests pin the
permanent index-zero offset.
