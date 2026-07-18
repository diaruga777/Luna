# Card Carousel (Downloader + Reader roots)

The Downloader's root screen is a carousel of vertical cards — one saved item per
card — instead of a grid + pushed viewer. The machinery is **generic and
surface-agnostic** and lives in `LunaLibraries/Sources/LunaDesignSystem/CardCarousel/`
(LunaDesignSystem is already linked by all three apps, so Reader can adopt it with its
own adapters later). The Downloader-specific adapters live in
`Luna/Downloader/SavedMediaCardsViewController.swift`.

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
- Above the cards: the host's `NavHeaderBar` (same settings/friends/add controls as
  before). Below: the scrub strip (`CarouselScrubberView`), one small 9:16 thumbnail
  per card. The download-progress footer floats above the safe-area bottom as before.

## Interaction model

- **Autoplay**: the centered card's content autoplays and loops as soon as it is
  centered (`CardContentViewController.cardDidBecomeCentered`); it pauses when it
  leaves center, keeping position.
- **Tap** the centered card: pause/play. **Horizontal drag inside** it: scrubs the
  playback timestamp (one card-width ≈ full duration). The card itself never pans.
- **Paging** happens outside the card: a horizontal drag on the insets left/right of
  the card drives the eclipse transition *interactively* — it tracks the finger,
  plays forward and back, and on release finishes (past 50%, or a committed flick)
  or reverses back to rest. A tap on a peeked edge pages one card. A flick on the
  scrub strip pages one card; dragging through the strip previews cards
  continuously (thumbnail overlay over the center card) and commits the index
  under the finger on release.
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
  (Photos-backed).
- `AnimatedImageCardContentViewController` — GIFs decoded once via ImageIO
  (downsampled) and driven by a CADisplayLink, so GIFs loop *and* scrub by frame
  (the old viewer showed GIFs as static images).
- `ImageCardContentViewController` — static aspect-fit image with an async loader.

Downloader adds `UndownloadedMediaCardContentViewController` (download glyph +
progress ring; observes `.downloaderJobProgressChanged` itself, keyed by its own
source URL).

## The eclipse page transition

`CardEclipseTransition` stages every single-step page as a solar eclipse
(Reduce Motion and multi-card jumps get a crossfade instead). Its ingress runs
inside a `UIViewPropertyAnimator`, so the inset pan scrubs it with the finger
(forward and back); releasing continues to the zenith or reverses to rest. Taps
and scrub-strip flicks run the same transition non-interactively.

1. **Ingress (~66%)** — the incoming side card (the moon) slides over the stationary
   outgoing card, growing from `sideScale` to a 1.03 overshoot (guaranteeing total
   coverage), its resting 70% dim easing to 60% across the crossing and snapping to
   0% in the last 15% — full color right at the zenith. The outgoing card lightens
   via a white overlay — subtle (0.18) for the first 55%, then very fast toward
   0.92 — while a corona (white rounded-rect shadow behind the card) blooms and
   spikes to full at the moment of overlap, and a black dimmer darkens the rest of
   the screen (cards region + scrub strip; the header stays lit). In the last
   quarter, a point-like radial "diamond-ring" star flares at the edge covered last
   (left edge paging forward, right edge paging backward), centered vertically —
   the last sliver of sun. Meanwhile the peek card on the *opposite* side fades to
   black, merging with the darkened background.
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

## Store plumbing (Downloader host)

`SavedMediaCardsViewController` keeps the grid's plumbing: cross-process Darwin
bridge, `.savedMediaChanged`/`.readingListChanged`/foreground/activation reloads,
expiry purge, Photos reconciliation (full `.authorized` only), long-press context
menu (Download / Share / Save to Photos / Delete), mark-opened on centering, and the
`DownloaderProgressFooterView`. Reloads are fingerprinted
(`id|thumbnail|storageState` per item) so store notifications that change nothing
visible don't rebuild live card content mid-playback; real changes reload while
keeping the currently centered item centered by id.

The old `SavedMediaGridViewController` + `SavedMediaViewerViewController` were
deleted with this change (the carousel replaces both).

## Reader adoption (ArticleCardsViewController)

The Reader app's root (`Luna/Reader/ArticleCardsViewController.swift`) replaces
`ReadingListViewController` for `.reader` only (Price Tracker keeps the list).
Differences from the Downloader, via `CardCarouselStyle`:

- `fillsVertically` (aspect ignored — cards take all height), `edgeGap` 10
  (card closer to the screen edges), `pagesOnInCardSwipes` (horizontal swipes
  inside the card page — readers have no timeline to scrub; the page pan
  recognizes simultaneously with the reader's own gestures, gated to
  strongly-horizontal drags), `.titles` scrubber (bigger chips showing article
  titles instead of thumbnails).
- The CENTERED card embeds a live `RabbitHoleReaderViewController`
  (`ReaderHostFactory.make`); side cards show a cover+title preview
  (`thumbnailFileName` art under a scrim), keeping one live reader mounted.
- **Expansion**: tapping the centered card — including on a link, since the
  carousel tap never cancels touches — or the first user-driven vertical
  scroll (KVO on the reader's scroll views, `isDragging`-filtered) detaches
  the live reader from the card and pushes the SAME instance fullscreen via
  `CardExpandTransitionCenter` (LunaTransitions): a subtle grow-from-card
  push / shrink-back pop, consulted first in `DotMatrixNavigationDelegate`.
  Starting RSVP playback expands because the play tap is a card tap.
- **Long-press** on the centered card: RSVP popover (`RSVPViewController` in a
  real `.popover`, adaptation forced to `.none`) without going fullscreen.
  Expansion is suppressed for 0.4s around its dismissal so the outside tap
  doesn't expand.
- Catch-up moved from the old list's scrolling header row into the pinned
  NavHeaderBar (same rectangle.stack icon + red dot); `CatchUpViewController`'s
  router is now the `CatchUpRouting` protocol so both roots can present it.
- SceneDelegate's two `as? ReadingListViewController` casts now handle both
  roots (deep-link `openReader` → `openExternally(_:)`; friend prompt presents
  from whatever the root is). needsCaptcha cards route through the same
  archive.today modal flow as the old list.
