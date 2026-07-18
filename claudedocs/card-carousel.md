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
- Above Downloader cards: the host's `NavHeaderBar`. Below: the scrub strip
  (`CarouselScrubberView`), one small 9:16 thumbnail per card. The Reader gives the
  strip a wider horizontal inset and flanks it with 44pt Liquid Glass Settings and Share
  circles. The download-progress footer floats above the safe-area bottom as before.

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
  under the finger on release. The strip keeps the selected chip centered in
  its viewport (clamped at the ends); only while a positional drag is live
  does it fall back to keep-visible scrolling, so the content never shifts
  under the stationary finger.
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
  strongly-horizontal drags), `.miniCards` scrubber: each chip is a miniature
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
  Dragging the strip shows the title instantly,
  then mounts the previewed card's REAL live content into the overlay once the
  finger rests on a chip for ~120ms (debounced so sweeping across chips doesn't
  build a reader per chip) — scrubbed-to cards render their full contents, not
  a bare title card.
- EVERY mounted card (centered + both side peeks) embeds a full live
  `RabbitHoleReaderViewController` (`ReaderHostFactory.make`), laid out to the
  card's bounds — the card view IS the fullscreen reader view (one header, one
  layout for both states), and paging never shows a placeholder. The layer
  header is not a bar: back (inline-reader layers only) or Pasteboard (root
  layer when a URL is available) occupies top-left, the mode switcher remains
  centered, and read-aloud sits top-right. Share is the bottom-right floating
  circle. The ROOT layer shows no back pill; deeper inline layers do.
- Reader cards use a real Liquid Glass edge surface: a `UIGlassEffect` view is
  masked to a narrow rounded ring over the card content, with a trait-aware
  hairline highlight. The rim refracts the page beneath it instead of drawing
  only a flat border. It fades to zero with the side cards, mini carousel, and
  floating controls whenever scrolling or RSVP playback enters immersion.
- On the Reader root, that control row is hosted at screen level over a
  backdrop-only ultra-thin material spanning the complete top safe area and
  header. The carousel and reader content extend behind it; the scroll reader
  reserves the row with `contentInset.top`, so its resting first line stays
  clear while scrolled/overscrolled content is blurred underneath. The overlay
  has no fill, separator, border, or shadow. Its opacity is zero at the resting
  scroll position and ramps in only as content crosses beneath it, so UIKit's
  material tint cannot reveal a band against a uniform light or dark page.
- **"Fullscreen" is a chrome fade, nothing more** — no navigation push, no
  card-geometry choreography. `CardCarouselViewController.setImmersed(_:animated:)`
  fades the peeking side cards and the scrub strip out and extends only the
  centered card's bottom edge into the room the strip frees up (top, sides,
  corner radius, and the reader's own header pills never move or change;
  paging, peek taps, and the strip are inert while immersed).
  The host fades its flanking Settings/Share circles in step via the carousel's
  `onImmersionChanged` callback, which also covers the internal reset on a
  reload.
  The card content drives it directionally from the embedded reader (KVO on
  its scroll views, re-swept via
  `RabbitHoleReaderViewController.onContentHierarchyChanged` when a dive/pop/
  mode switch swaps them, sampled synchronously so flicks aren't misread as
  settled): **scrolling down** past a small directional run (24pt, resetting
  on direction flips so jitter can't toggle it) fades the chrome away;
  **scrolling up — from anywhere in the article —** (12pt, or reaching the
  top) fades it back in. In **RSVP**, playing fades it away and pausing
  brings it back (`RSVPViewController.onPlaybackStateChanged`).
- **Long-press** on the centered card: RSVP popover (`RSVPViewController` in a
  real `.popover`, adaptation forced to `.none`) without going fullscreen.
- The cards root has NO header bar (and no catch-up entry — catch-up remains
  on the list root, `ReadingListViewController`, used by the other surfaces;
  `CatchUpViewController`'s router is the `CatchUpRouting` protocol).
- A new pasteboard URL is represented as a synthetic leading card (so it is
  visible as the left peek) and as a `doc.on.clipboard` mini-card in the scrubber.
  Tapping the card/chip or swiping onto it saves through the normal ingest
  pipeline. The same action is available from the outer reader's top-left while
  the root article layer is showing; inline reader depth replaces it with Back.
  Availability uses `UIPasteboard.detectPatterns(.probableWebURL)`, so opening
  Luna does not raise a paste-permission prompt; the URL value is read only after
  the user taps/swipes to add it. The consumed pasteboard change-count is
  suppressed until the clipboard changes.
- Settings and Share flank the mini-card scrubber in Liquid Glass circles instead of
  consuming header space. Friends is reached from Settings. The card begins
  directly below the safe area, so the reader's own header pills own the top row.
- SceneDelegate's two `as? ReadingListViewController` casts now handle both
  roots (deep-link `openReader` → `openExternally(_:)`; friend prompt presents
  from whatever the root is). needsCaptcha cards route through the same
  archive.today modal flow as the old list.
