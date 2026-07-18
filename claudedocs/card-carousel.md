# Card Carousel (Downloader root; Reader adoption planned)

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
- The centered card rests at scale 1; each neighbor rests at `sideScale` (0.92) with
  exactly `peek` (14pt) of its edge visible inside the screen edge. All geometry is
  pure math in `CardCarouselMetrics` (unit-tested in `CardCarouselMetricsTests`).
- Above the cards: the host's `NavHeaderBar` (same settings/friends/add controls as
  before). Below: the scrub strip (`CarouselScrubberView`), one small 9:16 thumbnail
  per card. The download-progress footer floats above the safe-area bottom as before.

## Interaction model

- **Autoplay**: the centered card's content autoplays and loops as soon as it is
  centered (`CardContentViewController.cardDidBecomeCentered`); it pauses when it
  leaves center, keeping position.
- **Tap** the centered card: pause/play. **Horizontal drag inside** it: scrubs the
  playback timestamp (one card-width ≈ full duration). The card itself never pans.
- **Paging** happens outside the card: a quick swipe (or tap) on the insets left/right
  of the card pages one card; a flick on the scrub strip pages one card; dragging
  through the scrub strip previews cards continuously (thumbnail overlay over the
  center card) and commits the index under the finger on release.
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

`CardEclipseAnimator` animates every single-step page as a solar eclipse
(Reduce Motion and multi-card jumps get a crossfade instead):

1. **Ingress (~66%)** — the incoming side card (the moon) slides over the stationary
   outgoing card, growing from `sideScale` to a 1.03 overshoot (guaranteeing total
   coverage). The outgoing card lightens via a white overlay — subtle (0.18) for the
   first 55%, then very fast toward 0.92 — while a corona (white rounded-rect shadow
   behind the card) blooms and spikes to full at the moment of overlap, and a black
   dimmer darkens the rest of the screen (cards region + scrub strip; the header
   stays lit). In the last quarter, a point-like radial "diamond-ring" star flares at
   the edge covered last (left edge paging forward, right edge paging backward),
   centered vertically — the last sliver of sun. Meanwhile the peek card on the
   *opposite* side fades to black, merging with the darkened background.
2. **Zenith** — behind the veils, the carousel re-stacks slots
   (`performZenithSwap`): the far peek is unmounted, the outgoing card moves to the
   opposite peek slot (still veiled black), the next card mounts on the vacated side
   at alpha 0, and the newly centered content starts playing.
3. **Egress (~34%)** — dimmer/corona/flare fade, the incoming card settles from 1.03
   to 1.0, the opposite-side veil fades revealing the outgoing card's content now
   living there, and the new far peek fades in.

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
