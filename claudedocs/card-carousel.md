# Card Carousel (every app's root)

All four apps use a carousel of vertical cards — one saved item per card — as
their root presentation. The machinery is **generic and surface-agnostic** and
lives in `LunaLibraries/Sources/LunaDesignSystem/CardCarousel/` (LunaDesignSystem
is linked by every app).

## One deck, four kinds

**There is ONE deck implementation**: `CardCarouselHostViewController`
(`Luna/CardCarouselHost/`). It owns the carousel instance, the index arithmetic
over its cards, the six-phase reload with its fingerprint diff and its centering
ladder, the single `CardCarouselDataSource`/`CardCarouselDelegate` conformance,
the archive tray's item pipeline, the flanking Settings/share circles, and the
util card's save transition. None of that exists anywhere else — the three root
decks used to parallel-implement all of it.

What differs between four apps is what a card IS, and that arrives through
`CardDeckProviding` (`Luna/CardCarouselHost/CardDeckProvider.swift`): what a card
looks like, what its long press offers, where a tap goes, what deleting it
releases, and how its store is ordered, filtered, and watched. **Each deck view
controller is its own provider** (`deckProvider` returns `self`), so the
kind-specific code stays in the file it already lived in without a second object
or a retain cycle:

| File | What it contributes |
| --- | --- |
| `Luna/Reader/ArticleCardsViewController.swift` | articles (and, in the central app, every kind — see "all-kinds deck") plus the reader chrome stack |
| `Luna/Downloader/SavedMediaCardsViewController.swift` | media rows and failed saves |
| `Luna/PriceTracker/PriceTrackerCardsViewController.swift` | product cards |

The host keeps a flat `[CardDeckSlot]` — `id`, optional `urlString`,
`fingerprint` — and **takes the util card's offset off exactly once**, so a
provider never sees a carousel index at all. `CardDeckSlot.urlString` exists for
the Downloader, whose media rows are keyed by the MEDIA store's id: a util-card
save hands back a reading-list item whose id that row does not share, but whose
URL it does, so either key resolves.

Slot preparation is two steps on purpose. `deckPreparedSnapshot()` reads the
stores and computes the slots WITHOUT adopting them; only a reload that actually
goes ahead calls `deckCommitPreparedSnapshot()`. An abandoned reload must leave
the provider's typed arrays exactly as the carousel was built from them.

`ArticleCardsViewController` subclasses the host — the only deck that does —
because its cards are live readers and it has real screen-level chrome of its own
(header row, immersion, footer veil, hosted scroll indicator, inline second
column, eye-tracking adoption, animated archive/unarchive). It rides the shared
core through named hooks: `deckWillReload`, `deckWillApplyReload`,
`deckDidApplyReload`, `deckWillMountBottomControls`,
`deckDidMountBottomControls`, `deckDidCenterCard(at:)`,
`deckDidSurfaceForEdgePaging`, `configureTrailingBottomButton`,
`refreshTrailingBottomButton`, `deckAllowsArchivePull`,
`deckArchiveTrayOpenStateDidChange`, `deckReconcilesArchivePullOnReload`, and
`carouselTopClearance`.

## Layout

- Cards are portrait 9:16 (`CardCarouselMetrics.cardAspectRatio`), rounded
  (`CarouselCardView.cornerRadius`, continuous), filled `.secondarySystemBackground`
  so a letterboxed (aspect-fit) frame still reads as a card against
  `.systemBackground`.
- The centered card rests at scale 1, inset `peek + edgeGap` (14 + 30pt) from each
  screen edge — the `edgeGap` insets only the centered card, giving the areas
  beside it enough width for paging swipes. Each neighbor rests at `sideScale`
  (0.92) with exactly `peek` (14pt) of its edge visible inside the screen edge,
  under a `CarouselCardView.restingDimAlpha` (70%) black dim so the centered card
  carries the screen. All geometry is pure math in `CardCarouselMetrics`
  (unit-tested in `CardCarouselMetricsTests`).
- **On a wide container the card is capped at half the width minus padding**
  (`LunaLayout.cardWidthCap`; see "Wide containers" below). The subtracted inset
  is `wideEdgePadding + columnGap / 2`, so TWO capped cards plus the gap between
  them span exactly the container minus one padding each side — which is what
  lets the side-by-side inline reader reuse one card width for both columns
  instead of resizing the card it slides aside.
- All four roots have no header bar. The Downloader scrub strip is bounded between
  the inner edges of the 44pt Liquid Glass Settings and Share circles (64pt
  horizontal inset), with no edge blur that could show as a band on black.
  Its thumbnail pitch uses a 20pt gap. The Reader's miniature-card strip runs
  exactly from the Settings circle's trailing edge to the Share circle's leading
  edge. Its mini cards disappear through a transparent alpha mask near those
  bounds; no blur/white veil is drawn in either appearance. Downloader's Share circle
  opens the media share MENU (`MediaItemActions.shareMenuRows`, hung off the
  button by `ShareButtonMenu` exactly like the Reader's pill): Copy link and
  Share link over the original saved URL, plus Share video / GIF / image /
  audio once the file exists. The link is always shareable, so the circle shows
  for undownloaded cards too; only the util and failed-save cards hide it. Downloader has no Friends or Add
  button on the root; Friends remains reachable through Settings. Its 9:16
  thumbnail chips have a visible pitch gap and enough strip height for selection
  scaling/shadows, so neither selected nor neighboring previews overlap or clip.
  Price Tracker uses the same miniature-card strip: each chip is the product
  thumbnail with the app icon's **green tag silhouette only** (no magnifying
  glass) pinned bottom-trailing. Nothing floats above this bottom chrome:
  download progress is drawn inside the downloading item's own card (see
  "Store plumbing" below).

## Wide containers (iPad)

`LunaLayout` (LunaDesignSystem) is the ONE answer to "is there more room here",
asked as pure geometry over a container **width** rather than the device idiom —
an iPad in half-screen Split View and an iPhone are the same layout problem, and a
13" iPad in landscape is a different one from the same device in portrait. The
threshold is 700pt: above every iPhone (widest 440), below every iPad in portrait
(narrowest 744). Unit-tested through `CardCarouselMetricsTests`' wide cases.

Consequences for the deck:

- The card is capped at half the width minus padding, for **every** `CardFit`.
- That cap makes an `.aspectFromBottom` card SHORTER than the room instead of
  taller, so the overflow-upward branch has nothing to do and would strand the
  card under a band of dead space. It grows into the room and centers instead,
  bounded at `LunaLayout.tallestCardAspectRatio` (1:2) so it never becomes a
  sliver. `.aspectCentered` (media) is deliberately excluded — its content IS
  9:16, and a taller frame would only letterbox it.
- Everything pinned to the screen edges came loose from the card, so it follows
  the card's column instead: the scrub strip
  (`CardCarouselViewController.alignScrubberToCardColumn`, keeping the exact
  clearance it has on a phone) and the flanking Settings/Share circles
  (`CardCarouselHostViewController.alignBottomControlsToCardColumn`, each edge
  resolved independently so a deck stepped aside for a second column doesn't
  leave the trailing circle floating in the gap). Phone-shaped containers are
  left literally unchanged.
- The archive drawer was a fraction of the screen — two thirds of a 13" iPad is
  911pt of archive arc for its 128pt cells. The fraction is kept and then capped
  (`LunaLayout.drawerWidth`), and the deck cedes exactly the width the drawer
  takes rather than two thirds regardless.
- `setColumnAside(shift:animated:)` steps the whole deck sideways to make room for
  a second card (the side-by-side reader, `claudedocs/readers.md`). It is NOT
  immersion: the card keeps its chrome, its rim, its resting geometry and every
  touch — only its peeking neighbours leave, because they would sit underneath the
  new column, and paging/scrubbing are off while paired. Because
  `restingCenteredCardFrame` reports the shifted frame, host chrome anchored to
  the card travels with it for free.

## Interaction model

- **Archive arc**: Reader, Downloader, and Price Tracker each keep a distinct,
  non-card, chrome-less
  archive drawer just beyond the carousel's right edge — no background, no pull tab;
  the cells are the entire surface. Closed, the arc is fully offscreen away from the
  rightmost card; when the rightmost card centers AND the archive has items, the
  cells spring-peek in from the right edge (26pt). An empty archive never peeks but
  can still be pulled open (a util-only deck also allows the pull). The
  drawer is absent from the carousel count and scrubber. A leftward pull opens it
  over the right 2/3 of the screen while the card deck translates left by the
  same 2/3, ceding that space. The gesture is interactive in both
  directions; tapping the exposed outside area spring-dismisses it. `ArchiveTrayController`
  owns this shared presentation; `ArchiveArcLayout` (a custom
  `UICollectionViewLayout`) arranges an "archive" header cell plus narrowed item
  cells (drawer width − 56) along a circular arc whose pivot sits far off the right
  edge (radius ≈ 1.4× drawer height), so the column bows left. Vertical scrolling
  reinterprets as rotation: each item's position/tilt derives from its arc-length
  distance to the viewport midline, cells fanning spoke-like toward the pivot.
  The peek is card chrome: dismissing the chrome (reader immersion) fades the
  closed arc out with the side-card peeks/scrub strip (same 0.32s ease-in-out,
  pull disabled while hidden) and it fades back when the chrome returns.
  Long-pressing an item cell offers Unarchive and Share; all three surfaces also
  offer a destructive Delete that removes the complete save
  through the surface's normal cleanup path. Reader unarchive writes immediately,
  bumps the article to the first active position, and cross-dissolves the tray-cell
  snapshot into the centered card's final content while the tray spring-dismisses;
  the mismatched cell/card aspect ratios are never interpolated or stretched.
  The carousel reports its intended
  navigation target before card motion begins: scrubbing, tapping a scrubber chip,
  or swiping away from the rightmost card retracts the tray concurrently instead
  of waiting for the card swap. Paging toward the rightmost card reveals the tab
  only after that card centers; cancelling a page restores it after settling.

- **Permanent util card**: index zero is a normal carousel card, not a tray. It
  is always counted and always represented in the scrubber by the current app's
  action-extension icon. An empty deck centers it; otherwise index one, the first
  save, remains the launch selection. The util card owns first-run headline and
  setup actions until completion, then uses that space for matching Safari
  history. The real `UIPasteControl` row remains in both states; the Save of the
  Week row appears in either whenever there is a live signed entry
  (`save-of-the-week.md`). See `util-card.md`.

- **Autoplay**: the centered card's content autoplays and loops as soon as it is
  centered (`CardContentViewController.cardDidBecomeCentered`); it pauses when it
  leaves center, keeping position.
- **Tap** the centered card: pause/play. **Horizontal drag inside** it: scrubs the
  playback timestamp (one card-width ≈ full duration).
  The card itself never pans — and on decks that page on in-card swipes (the
  all-kinds deck's readers), a playable card is exempt: its whole width is a
  timeline, so the drag scrubs and never ALSO pages
  (`CardCarouselPagePanStartPolicy`, `centeredContentScrubs`). Edge swipes and
  the strip stay the paging affordances. Playback starts the instant a card
  centers: the player never waits to minimize stalling (everything is local),
  and a neighbor card pre-decodes its first frame with a zero-tolerance seek at
  install.
- **A PAUSED card shows its playback controls**, and they are a function of the
  paused state rather than of any gesture: a `MoonHorizonProgressBar` sits INSIDE
  the card's bottom edge (12pt up — the mute button's inset from the top), bare
  over the video — it carries no backdrop of its own. The bar shows only
  determinate progress and the head point — the traveling activity pulse remains
  exclusive to download progress. Content that plays at a chooseable rate also
  gets a **glass speed pill** floating above the bar's leading end (the pill
  re-fits its frame on every speed change — it is frame-managed, and "0.25×" is
  wider than "1×"). One tap opens its menu:
  0.25× / 0.5× / 1× / 1.5× / 2×, the current one checked
  (`PlaybackSpeedPillButton`, `PlaybackSpeed.options`).
  Because the pause a drag-scrub performs is the same pause, the bar comes up
  for the duration of a seek as before — and now STAYS up if the drag ends
  paused. Resuming takes both controls down.
  **The opt-in is the CONTENT's**, `showsPlaybackScrubProgress` (video yes, GIF
  no) plus `supportsPlaybackSpeed` for the pill; there is no deck-level style
  flag, so the Downloader's deck and the central app's all-kinds deck cannot
  disagree about the same media card. "At rest" is enforced: a transition, a
  live scrub preview, immersion, a stepped-aside column or a card paged away
  (paused too) shows nothing. Content reports every play/pause through
  `playbackStateChanged`, which is the one input to
  `updatePlaybackControls()`.
- **Speed is remembered per ITEM, in memory only** (`PlaybackSpeedMemory`, keyed
  for media by `MediaCardFactory.speedMemoryKey` = the row id). A card is
  destroyed two slots out and rebuilt on the way back, so the memory outlives the
  player; the process forgets. `AVPlayer.defaultRate` carries it, so loops and
  foregrounding resume at the chosen speed, and `.spectral` pitch keeps voices
  their own at 0.25× and 2×. Fullscreen playback (the archive tray's
  `AVPlayerViewController`) keeps the SYSTEM speed menu — Luna draws no second
  control there — but shares the same memory in both directions and offers
  Luna's five speeds.
- **Paging** happens outside the card: a horizontal drag on the insets left/right of
  the card drives the eclipse transition *interactively* — it tracks the finger,
  with 1.5× horizontal movement on both the Reader and Downloader root screens,
  plays forward and back, and on release finishes (past 50%, or with enough
  release velocity toward the target) or reverses back to rest. A tap on a
  peeked edge pages one card. The scrub strip scrolls natively like a
  miniature carousel: the chip at its viewport center is the live selection —
  panning left brings chips (and cards) in from the right, each chip passing
  center previews its card over the centered card — and releasing decelerates
  (`decelerationRate = .fast`) to the nearest chip dead-center via a
  `targetContentOffset` snap, then commits it. Symmetric content insets let
  even the first and last chips center exactly; at rest the selected chip is
  always centered, whatever selected it (scrub, tap, or card swipe), with a
  selection haptic whenever a new chip crosses center during a drag. A tap on
  a chip commits it directly and always uses the same eclipse transition on
  both Reader mini cards and Downloader thumbnails, whether the target is
  adjacent or farther away. An unmounted target is staged at the incoming peek,
  then its new neighboring window is laid out behind totality before the reveal.
  Chips
  alpha-fade out near the strip's ends
  (`CardCarouselStyle.scrubberEdgeFadeWidth` → `CarouselScrubberView
  .edgeFadeWidth`: a non-scrolling transparent gradient mask, with no drawn veil).
- **The scrub preview is the whole deck, in real card chrome**
  (`CarouselScrubPreviewController`). It draws THREE cards — the previewed one
  and both peeks — as genuine `CarouselCardView`s built by the same
  `makeCardView(at:)` the mounted slots use and rested at the same geometry via
  the shared `applyRestingLayout(to:atSlotOffset:)`, so the glass rim, the mute
  button, and the Photos badge stay put and the peeks track the finger instead
  of freezing on the committed card's neighbors. The real slots stay mounted
  (their content stays alive) but hide underneath for the gesture. Each preview
  shows, in order of preference: its mounted real content, its thumbnail, its
  title. Previews are recycled by CARD, not by position — advancing one chip
  slides the center out to a peek with its content and thumbnail intact.
  Peeks only mount content that is ALREADY prepared for the strip's visible
  window (sweeping the finger must never spin up a player or a reader per chip)
  and never play.
  The Downloader opts into `autoplaysScrubPreviewContent`: as each thumbnail
  reaches the strip's center, the center preview mounts that card's real content
  immediately and autoplays it using the carousel's current mute state
  (including looping videos and GIFs). Moving
  to another thumbnail stops and replaces that temporary preview player. On
  release, the selected preview controller is promoted into the centered card
  without replacing its player or timestamp, so playback continues smoothly —
  and the preview cards stay up until the real window is mounted and laid out
  beneath them, so nothing blinks (there is no chrome fade-in any more: the
  chrome was never missing). The Photos control opens that Photos-backed asset
  in the Photos app.
- **Audio** is off by default (`CardCarouselViewController.isSoundMuted`, carousel-
  wide). The mute/unmute button sits at the card's top-right and only shows when the
  content reports `supportsAudio` (videos discover their audio track async). Pressing
  a hardware volume key also unmutes (KVO on `AVAudioSession.outputVolume`). The
  carousel keeps the session `.ambient(mixWithOthers)` while muted and `.playback`
  when unmuted (`managesAudioSession` opts out for hosts with their own audio stack).

## Content controllers

`CardContentViewController` is the open base contract (playable/duration/fraction/
seek/mute/centered hooks). Generic implementations:

- `VideoCardContentViewController` — AVPlayer, manual loop on end-notification (so
  scrubbing stays in our control), zero-tolerance seeks, poster image until first
  frame (`isReadyForDisplay`), local-file or async `AVPlayerItem` provider
  (Photos-backed). Takes an optional `speedMemoryKey`: the ITEM it is showing,
  which is what the chosen playback speed is remembered against.
- `AnimatedImageCardContentViewController` — GIFs decoded once via ImageIO
  (downsampled) and driven by a CADisplayLink, so GIFs loop *and* scrub by frame
  (the old viewer showed GIFs as static images).
- `ImageCardContentViewController` — static aspect-fit image with an async loader.

Downloader adds `UndownloadedMediaCardContentViewController` (download glyph +
progress ring; observes `.downloaderJobProgressChanged` itself, keyed by its own
source URL).

~~**The synthetic pasteboard card**~~ (DELETED). Both the Reader's and the
Downloader's decks used to prepend a synthetic leading card driven by
`detectPatterns(.probableWebURL)`: Reader resolved a full unsaved live reader on
it and persisted when reading dismissed the chrome, and Downloader staged the
media to a one-hour temporary file and committed it on the first explicit Play.
Paste moved permanently onto the util card's own `UIPasteControl` row and neither
deck has created that card since — `refreshPasteboardURL` had no caller — so the
whole layer is gone: `PasteboardLinkProbe`, `PasteboardCommitPolicy`,
`PasteboardTemporaryMediaPolicy`, the four synthetic card content controllers,
both decks' state machines, and the `"paste|"` element the reload fingerprint
carried for it. Removing that element left an empty deck fingerprinting as `[]` —
the initial value of `appliedFingerprint` — which is why the host has a
`hasAppliedSnapshot` first-reload guard.

## The eclipse page transition

`CardEclipseTransition` stages every single-step page and every direct scrubber
tap as a solar eclipse (Reduce Motion and non-tap multi-card jumps get a crossfade
instead). Peek taps and interactive paging retain the deliberate 0.62-second
timing; direct scrubber taps use the same keyframes at a brisker 0.44 seconds.
Its ingress runs
inside a `UIViewPropertyAnimator`, so the inset pan scrubs it with the finger
(forward and back); releasing continues to the zenith or reverses to rest. Taps
and scrubber taps run the same transition non-interactively.

1. **Ingress (~66%)** — the incoming side card (the moon) slides over the stationary
   outgoing card, growing from `sideScale` to a 1.03 overshoot (guaranteeing total
   coverage), its resting 70% dim easing to 60% across the crossing and snapping to
   0% in the last 15% — full color right at the zenith. The outgoing card holds
   almost unchanged for the first 80% of the crossing (white overlay pinned at
   0.06, corona at 0.08), then both spike steeply in the final 20% — the overlay
   flashes to 0.92 and the corona (two stacked white rounded-rect shadows behind
   the card: a tight hot rim + a wide soft halo) blooms to full right at the
   moment of overlap — while a black dimmer gradually darkens the rest of the
   screen (cards region + scrub strip; the header stays lit). In the last ~18%, a
   star-shaped "diamond-ring" point light — white-hot core with a very quick
   radial falloff, four long axis spikes + four shorter diagonals
   (`EclipseFlareView`) — flares at the edge covered last (left edge paging
   forward, right edge paging backward), centered vertically — the last sliver of
   sun. Meanwhile the peek card on the *opposite* side fades to black, merging
   with the darkened background.
2. **Zenith** — behind the veils, the carousel re-stacks slots
   (`performZenithSwap`): the far peek is unmounted, the outgoing card moves to the
   opposite peek slot (still veiled black), the next card mounts on the vacated side
   at alpha 0, and the newly centered content starts playing.
3. **Egress (~34%)** — dimmer/corona/flare fade, the incoming card settles from 1.03
   to 1.0, the opposite-side veil fades revealing the outgoing card now living
   there (at the resting side-card dim), and the new far peek fades in.

A reload arriving mid-transition is deferred until the transition settles
(`pendingReload` in the carousel) — tearing slots down under a running transition
would strand its captured card views as duplicates — and `removeOrphanCardViews`
structurally guarantees no card view outlives its slot.

## A new save takes the center

Every deck — Reader's, the central app's all-kinds deck, Downloader's, Price
Tracker's — moves to a save it has never shown, whatever added it and whenever
it arrived: the util card, the share/action/Safari extension,
an App Intent, the mailbox importer, or a sibling app writing the shared store
while this one was suspended or dead.

**One ladder, in the host, for every app**, resolved once per applied reload:

1. **A save this deck has never shown.** Highest, unconditionally.
2. The archive choreography's intended successor
   (`pendingTransitionCenteredID`) — not a new save, so it sits below one, but
   above the parked card: the store write happens first and the animation
   snapshot needs its destination already under it.
3. A save the deck is still waiting to see appear (`requestCentering`) — an
   in-app util-card save, the price editor's Save, a row coming back out of the
   archive. Kept until it resolves, because the row a save becomes can appear a
   notification later than the save itself (the Downloader's media row is
   written by a second store).
4. The card the user was parked on, by identity.
5. The deck's default: its newest save, or the util card when it has none.

Price Tracker used to resolve (3) above (4) while Reader and Downloader resolved
it below; that divergence is gone and the ladder above is the rule everywhere.
**Nothing is gated on a save having been made interactively.**

The decks don't ask each entry point to announce itself. Every reload hands its
card ids to `CardCarouselHostViewController.newSaveItemIndex(cardIDs:offstageIDs:)`,
which compares them against the previous snapshot: any id that wasn't there
arrived since, however it got here. With several new saves, the first in card
order centers, which on every deck's newest-first ordering is the most recent one.

A save selected from the util card adds one extra visual handoff shared by all
surface hosts: the tapped URL row's empty shell travels to the carousel's
resting card frame and expands, while its thumbnail and title travel separately
into normal favicon/title-header geometry instead of stretching with the shell.
After the mounted destination is ready, its real contents crossfade over that
temporary header. The destination card is revealed only when the handoff
finishes. This is separate from new-save detection—the normal store reload still
decides which card centers.

Two things deliberately don't count as new. `offstageIDs` (archived rows) are
passed in as seen, so unarchiving one reads as the return of a known card and
leaves the archive tray's own transition in charge of where it lands. And the
first snapshot only seeds the set — a deck that has shown nothing has nothing
new, and its newest-first default already opens on the most recent save.

Covered by `NewSaveCenteringTests` (all three decks, end to end, plus the shared
seam in isolation).

## Store plumbing (Downloader provider)

`SavedMediaCardsViewController` keeps the grid's plumbing: cross-process Darwin
bridge (`deckWillBeginObservingStores`),
`.savedMediaChanged`/`.readingListChanged`/foreground/activation reloads
(`deckChangeNotificationNames` + `deckActivationNotificationNames`), expiry purge,
Photos reconciliation (full `.authorized` only, in `deckDidSettleReload` so a
reload that changed nothing still notices a vanished asset), long-press context
menu (Download / Share / Save to Photos / Archive / Delete), and mark-opened on
centering. Its slot fingerprint is `id|thumbnail|storageState`, so store
notifications that change nothing visible don't rebuild live card content
mid-playback.

**Its failed saves are SLOTS, not a second index space.** A save whose ingestion
failed carries no kind, so the surface gate keeps it and every app shows it —
this app included. Those cards sit after the media rows in the same
`[CardDeckSlot]` list. This deck used to keep two index maps (`mediaIndex` /
`failedIndex`) that every data-source method probed, and they disagreed in two
places, both now fixed:

- Parking on a failed-save card survives a reload. `centeredID` was read out of
  the media array only, so a failed card gave nil and the deck fell back to the
  first media row.
- The archive tray's pull activates on the last CARD. `canPull` compared
  `currentIndex` against `items.count + cardOffset` — the last MEDIA card — while
  `navigationTargetDidChangeTo` correctly counted the failed saves too, so with
  failed saves present the pull turned on mid-deck and never on the true end.

Covered by `SavedMediaDeckSlotTests`.

The verbs a media row offers, and the storage work behind two of them, live once
in `MediaItemActions` (`Luna/Downloader/MediaCardFactory.swift`): the switch over
`storageState` that decides the menu, the manual-download start, the
save-to-Photos copy, the companion-storage release, and the `storageStateKey`
both this deck and the all-kinds deck fingerprint a media card by. Two decks show
the same media save, and they were answering "what can you do with this?" and
"what goes when it goes?" with two copies of the same code.

**Download progress is never floating chrome.** The app-level
`DownloaderProgressFooterView` was deleted: an in-flight download is drawn inside
the card of the item downloading it (the undownloaded card's own glass status bar
— see `claudedocs/media-download.md`), or, for an archived row re-downloading in
place, on that row's archive-tray cell (`ArchiveTrayController.setDownloadProgress`
updates visible cells without a reload, since ticks arrive several times a
second). Every such view is a pure observer of
`.downloaderJobProgressChanged`; the transfer lives in
`LiveMediaDownloadManager`'s background `URLSession`, so paging the card away,
leaving the screen, or backgrounding the app does not pause or cancel it, and a
card that returns mid-transfer re-reads `currentDownloadSnapshot` to resume its
bar.

The old `SavedMediaGridViewController` + `SavedMediaViewerViewController` were
deleted with this change (the carousel replaces both).

## Reader adoption (ArticleCardsViewController)

The Reader app's root (`Luna/Reader/ArticleCardsViewController.swift`) replaces
`ReadingListViewController` for `.reader` only (Price Tracker kept the list at the time). **Since superseded:** every app roots on a deck and that list has been deleted.
Differences from the Downloader, via `CardCarouselStyle`:

- `cardFit = .aspectFromBottom` (the card is exactly 9:16 — the
  Shorts/Reels/TikTok portrait shape the media cards already use — at the full
  width the peeks leave, which is TALLER than the room between the header row
  and the scrub strip: the card's bottom edge stays on the strip and the extra
  height is added at the top, growing up through `cardTopOverflow` points of
  header-row clearance to the safe-area top and no further. On a 402×874pt
  screen that's a 354×629 card whose top sits at y≈95, so the header row's
  buttons float over the card's (fade-masked) top edge. A container too wide for
  the allowance — iPad — keeps the aspect exact by narrowing instead), `edgeGap` 10
  (card closer to the screen edges), `pagesOnInCardSwipes` (horizontal swipes
  inside the card page — readers have no timeline to scrub; the page pan
  recognizes simultaneously with the reader's own gestures, gated to
  strongly-horizontal drags — EXCEPT over a `UISlider`: a drag that starts on
  a horizontal control (the RSVP scrubber) is a scrub, and near the track's
  ends it reads exactly like a page-worthy swipe, so `pagePan` refuses to
  begin there rather than paging the card out from under the thumb.
  **A swipe that BECOMES a page stops being anything else.** Simultaneous
  recognition is what keeps links, taps and scrolling alive on a card that is
  not being paged, so by the time the horizontal gate opens, the reader under
  the finger has usually begun its own scroll on the same touch — and every
  vertical wobble of the rest of the swipe scrolled the article while the deck
  paged it away. Most visible starting on a peeking side card, whose reader is
  live too: the finger arrived at the newly centered card already scrolled off
  its first line. `pagePan`'s `.began` now cancels every scroll view inside
  `cardArea` that is tracking that touch (`CardCarouselScrollViews.nested`;
  toggling `isEnabled` is the only mid-sequence cancel, and the state check
  leaves a card decelerating from an earlier flick alone), and
  `CardCarouselPagePanSimultaneityPolicy` refuses a scroll view that asks to
  start *after* the pan is already tracking. The reverse case is untouched: a
  drag that starts vertical fails the horizontal gate, so `pagePan` never
  begins and the article scrolls as before), `.miniCards` scrubber: each chip is a miniature
  article card — a tiny `.systemBackground` surface with skeleton headline/body
  bars and a source badge as its masthead. The badge (`CarouselSourceBadge` in
  LunaDesignSystem, rendered by `CarouselSourceBadgeView`) is the site's
  favicon for web saves — fetched by `FaviconFetcher` (LunaFetch: well-known
  apple-touch-icon path → homepage `<link rel*=icon>` candidates ranked
  touch-icon-first/largest-first → `/favicon.ico`, every response validated as
  a decodable raster image) and cached by `SourceIconCache` (app shell:
  memory + `Caches/SourceIcons/<host>.png` + 7-day negative cache + in-flight
  de-dup). Email imports show the sender's initials on a name-derived pastel
  (or an envelope glyph when the sender is unknown), documents a doc glyph,
  and web saves a globe until the favicon lands (the data-source callback may
  fire twice: instant fallback, then the fetched icon —
  `ArticleSourceBadge.fallback(for:)`, unit-tested in `SourceBadgeTests`).
  Scrolling the strip shows the exact reader card that will be selected,
  including its current mode, content hierarchy, and saved reading position.
  The carousel prepares real card controllers only for chips intersecting the
  scrubber viewport, releases prepared controllers as they leave that window,
  and promotes the live preview controller directly into the centered slot on
  commit. Reader previews remain on the scroll reader's Phase-1 prefix: only
  enough text and inline images for the visible content window are laid out or
  loaded. Promotion of that same controller permanently lifts the primary gate
  and starts the seamless Phase-2 full-content swap. Programmatic offsets from
  that swap are presentation-silent: they neither flash the horizon indicator
  nor momentarily exchange the pinned and scrolling title copies. The preview
  therefore cannot swap to different content when the strip settles, while
  whole-article layout and image loading stay off the scrub path. A deep saved
  position still renders enough content up front to restore its actual viewport.
- EVERY mounted card (centered + both side peeks) embeds a full live
  `RabbitHoleReaderViewController` (`ReaderHostFactory.make`), laid out to the
  card's bounds — the card view IS the fullscreen reader view (one header, one
  layout for both states), and paging never shows a placeholder. The layer
  header is not a bar: the top-left circle is back (inline-reader layers only),
  or the RSVP eye-tracking toggle the deck adopts from the focused reader, and
  read-aloud sits top-right.
  The mode switcher occupies the bottom-center lane only while card chrome is
  dismissed, replacing the mini carousel there; the two controls trade places
  with a short translation + fade. Share is the bottom-right floating circle.
  The ROOT layer shows no back pill; deeper inline layers do.
- Reader cards use a real Liquid Glass edge surface: a `UIGlassEffect` view is
  masked to a narrow rounded ring over the card content, with a trait-aware
  hairline highlight. The rim refracts the page beneath it instead of drawing
  only a flat border. It fades to zero with the side cards and mini carousel
  whenever scrolling or RSVP playback enters immersion. The mask MUST be the
  view-level `UIView.mask` — `UIVisualEffectView` silently ignores
  `layer.mask`, which frosts the entire card.
- On the Reader root, the control row is hosted at screen level over the bare
  screen background — no bar, fill, or blur behind it — and the cards rest
  fully BELOW the row (`setTopInset`): the card frames only reader content,
  never the controls. There is no blur header/footer anywhere. Instead, card
  content dissolves over `CardCarouselStyle.contentEdgeFadeHeight` (Reader:
  28pt; 0 = hard clip, the default for other hosts) at the card's top and
  bottom edges via a gradient mask on the card's content container. The scroll
  reader reserves the top fade run with `contentInset.top`
  (`externalChromeContentInset`), so the resting first line starts fully
  legible; scrolled content fades away as it approaches an edge. RSVP takes
  the same measure as `RSVPViewController.topContentInset`: its reading
  layout deliberately ignores it (a centered word makes no use of the extra
  room), but the eye-tracking toggle is placed below it — the pinned title
  header is opaque and sits ABOVE the reader's view, so a toggle at the
  card's own corner would be behind it rather than beside it.
- **"Fullscreen" is a chrome fade, nothing more** — no navigation push, no
  card-geometry choreography. `CardCarouselViewController.setImmersed(_:extendsCard:animated:)`
  fades the peeking side cards and the scrub strip out and — for the scroll
  reader (`extendsCard: true`) — extends only the centered card's bottom edge
  into the room the strip frees up (top, sides, corner radius, and the
  reader's own content never moves or changes; peek taps and the strip are
  inert while immersed). The mini carousel fades and drifts down as the bottom
  mode switcher fades into its place; surfacing reverses that handoff. A
  horizontal pan beginning in either screen-edge
  inset synchronously restores the resting card geometry and carousel chrome,
  then continues that same gesture into interactive paging — immersion never
  requires a separate surfacing swipe. RSVP immerses with `extendsCard: false`:
  its layout is fixed (focal word, controls), so playing must not move
  anything on screen — the card frame holds and only the chrome fades. The
  extension would also have pushed the RSVP playback controls below
  `cardArea.bounds`, where hit-testing can't reach them. The immersed
  card also clears its surface tone (`setSurfaceHidden`) so the edge fades
  dissolve into the screen background instead of silhouetting the retired
  card. The screen-level corner controls and the flanking Settings/Share
  circles PERSIST through immersion; the bottom mode switcher appears only
  after carousel chrome is dismissed.
  **Arriving in RSVP surfaces the deck.** RSVP's chrome state IS its playback
  state, and a mode switch lands on a paused reader — so
  `readerContentHierarchyDidChange` asks
  `RabbitHoleReaderViewController.focusedRSVPIsPlaying` and reports that as the
  immersion state (`ReaderCardContentViewController`), rather than only
  retracting the outgoing scroll reader's card extension. Because the bottom
  mode switcher exists ONLY while chrome is dismissed, every switch into RSVP
  starts immersed; leaving the deck that way laid the fixed speed-reader column
  out against a card still stretched over the footer lane, with the chrome that
  named the mode faded away. Tapping the card immerses again and hands the lane
  back to the switcher. Test:
  `ArticleCardsChromeTests.testSwitchingToRSVPSurfacesTheWholeCardChrome`.
  The card content drives it directionally from the embedded reader (KVO on
  its scroll views, re-swept via
  `RabbitHoleReaderViewController.onContentHierarchyChanged` when a dive/pop/
  mode switch swaps them, sampled synchronously so flicks aren't misread as
  settled): **scrolling down** past a directional run (100pt, resetting
  on direction flips so jitter can't toggle it) fades the chrome away;
  **scrolling up — from anywhere in the article —** by 50pt fades it back in;
  reaching the top restores it immediately, and
  approaching the article bottom restores it when the content edge meets the
  resting card's future bottom edge. Downward dismissal is disabled from half a
  viewport before that bottom-restore boundary, preventing the directional and
  position rules from fighting during the final deceleration. Tapping plain reader content also toggles
  immersion, while links and inline images retain their normal actions. During
  scroll immersion, a screen-level dissolve becomes opaque at the top edge of
  the persistent Settings/Share buttons so content never bleeds into their
  footer safe area. In **RSVP**, playing fades it away and pausing
  brings it back (`RSVPViewController.onPlaybackStateChanged`).
- A card whose save **FAILED** is replaced wholesale by the shared error card
  (`claudedocs/failed-saves.md`) and carries a subtle red rim
  (`CardSurfaceView.setEdgeGlow`, supplied per card by the
  `edgeGlowColorForCardAt` data-source hook — the surface clips, so the glow is
  stroked just inside the edge and blooms inward). Its long-press menu drops
  Archive: Share Link and destructive Delete only. Failed saves appear on the
  Downloader root too (in the slots after the media cards) — they belong to no
  app, so every app shows them.
- **Long-press** on the centered Reader card offers Archive and destructive Delete.
  Archive persists immediately, then the old card drifts slightly upward while
  fading out before its next neighbor springs into the centered position. Archived
  article squares show favicon, title, and original save date; tapping opens the
  fully retained reader content; long-pressing offers Unarchive, Share, and
  destructive Delete. Both Delete actions remove the full save and owned files.
  Deleting the first saved card preserves the successor immediately to its right
  as the new center; the util card remains at index zero.
- The cards root has NO header bar.
- Paste lives permanently at the bottom of the util card. Its native
  `UIPasteControl` owns clipboard authorization, and a valid URL follows the same
  ingest, card handoff, and new-save centering path as weekly/recent util rows.
  The deck no longer creates a synthetic pasteboard card.
- Settings and Share flank the mini-card scrubber in Liquid Glass circles instead of
  consuming header space. Friends is reached from Settings. The card begins
  directly below the safe area, so the reader's own header pills own the top row.
- SceneDelegate's two root casts (then `as? ReadingListViewController`, now the `ExternalItemOpening` protocol) handle both
  roots (deep-link `openReader` → `openExternally(_:)`; friend prompt presents
  from whatever the root is). needsCaptcha cards route through the same
  archive.today modal flow as the old list.
- **An external open CENTERS the card; it does not push a reader.** In this deck a
  card already IS the reader, so the deep-link / Safari "Read in Luna" hand-off
  pushing a fullscreen reader buried the deck under a second copy of the same
  article and left a back button where the hand-off should simply have landed the
  user on the card. `ArticleCardsViewController.openExternally` therefore routes
  through `centerCard(forItemID:)`, which reuses the archive-tray transition's
  `pendingTransitionCenteredID` seam to pick up a just-saved item — but `reload()`
  early-returns on an unchanged fingerprint (the common case, since the save that
  preceded the open already reloaded the deck), so the target index is re-checked
  and centered directly afterwards. A `needsCaptcha` item centers FIRST and then
  presents its unlock flow, so the deck behind (and left by a cancel) already shows
  the right article. The fullscreen push survives only as the fallback for an item
  with no card here — an archived item, which is also how the archive tray's own
  `tap` opens. `LunaTests/ArticleCardsExternalOpenTests` (3).

## The central app's all-kinds deck

The same `ArticleCardsViewController` is the central Luna app's root, where
`LunaApp.current == .luna` turns on `includesAllKinds`: one deck over
every app's saves, **most recent first**. It deliberately drops the Reader's
read-vs-unread grouping — "read" is an article-only notion, and it would file a
just-watched video behind everything else.

A Downloader save is rendered here by the **Downloader's own card**, not as a
link: the looping player, the animated GIF, the full-resolution image, or the
in-card download progress bar, plus its Photos badge, its platform logo in the
scrub strip, and Share / Save to Photos in its long-press menu. The deck's
trailing share pill offers the same media ladder the Downloader's circle does
(Copy link / Share link / Share video…, via the seam's `shareMenu`); a platform
save with NO media row gets the two link verbs alone, and only the file row
ever shares a file — a video Luna holds just a thumbnail for shares its link,
never the thumbnail. Deleting the
card deletes the whole save — the downloaded file and its Photos asset with it.
Its tap belongs to the card content (play/pause, the download button); the
native-app → embed → in-app-browser ladder (`nonArticleOpener`) is left to the
link-style card that stands in when nothing has been downloaded yet, and to
price trackers, which still open the price editor.

`ArticleCardsViewController` is shared with **Luna Reader**, which links no
media module and so cannot name any of that. The deck therefore talks to an
`AllKindsCardProviding` seam — an inner seam, NESTED inside the article deck's
own `CardDeckProviding` conformance: the deck is the provider for the whole deck,
and `AllKindsCardProviding` is how the foreign kinds contribute to it (card
content, top-leading accessory, source badge, thumbnail, menu actions, the
trailing circle's share menu, companion-storage delete, per-item fingerprint,
change-notification names). Only
the central app compiles an implementation
(`AllKindsCardProvider`, installed beside `nonArticleOpener` by
`NonArticleCardOpening.install()`). The card construction itself lives in
`MediaCardFactory` (compiled into Luna + LunaDownloader), which the Downloader's
own deck uses too.

Two consequences worth knowing:

- The deck reloads on `.savedMediaChanged` (and `KindWiring+Luna.appDidLaunch`
  starts `SavedMediaStore.startObservingCrossProcessChanges()`), so a download
  that finishes in the background — or in an extension's process — turns a
  placeholder card into a player. The reload fingerprint includes the provider's
  per-item storage-state key, so that change actually re-renders.
- Media cards decline PREPARED scrub previews
  (`allowsPreparedPreviewContent`): the mini-card strip prepares content for its
  whole visible chip window, which would be an AVPlayer per chip. They preview
  as their poster thumbnail instead and build the real player on commit.
