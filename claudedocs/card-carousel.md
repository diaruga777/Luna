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
- Both roots have no header bar. The Downloader scrub strip is bounded between
  the inner edges of the 44pt Liquid Glass Settings and Share circles (64pt
  horizontal inset), with no edge blur that could show as a band on black.
  Its thumbnail pitch uses a 20pt gap. The Reader's miniature-card strip runs
  exactly from the Settings circle's trailing edge to the Share circle's leading
  edge. Its mini cards disappear through a transparent alpha mask near those
  bounds; no blur/white veil is drawn in either appearance. Downloader's Share circle
  exports the centered media file directly through the system share sheet and is
  hidden for pasteboard/undownloaded cards. Downloader has no Friends or Add
  button on the root; Friends remains reachable through Settings. Its 9:16
  thumbnail chips have a visible pitch gap and enough strip height for selection
  scaling/shadows, so neither selected nor neighboring previews overlap or clip.
  The download-progress footer floats above this bottom chrome.

## Interaction model

- **Archive tray**: Reader and Downloader each keep a distinct, non-card tray just
  beyond the carousel's right edge. Its vertical `archive` tab is fully offscreen
  away from the rightmost card, then spring-peeks in when the rightmost card becomes
  centered (the empty state also exposes it). The tray is absent from the carousel
  count and scrubber. A leftward pull opens the tray
  to 2/3 screen width, and shifts the card/empty UX left by 1/2 screen width. The
  gesture is interactive in both directions; tapping the exposed outside area
  spring-dismisses it. `ArchiveTrayController` owns this shared presentation and
  a vertically scrolling single-column list of wide rectangular items. Its opaque
  neutral background follows light/dark appearance and covers card chrome beneath
  it while open. Long-pressing a tray item offers Unarchive and Share; Downloader
  also offers a destructive Delete that removes the complete save through its
  normal cleanup path. The carousel reports its intended
  navigation target before card motion begins: scrubbing, tapping a scrubber chip,
  or swiping away from the rightmost card retracts the tray concurrently instead
  of waiting for the card swap. Paging toward the rightmost card reveals the tab
  only after that card centers; cancelling a page restores it after settling.

- **Autoplay**: the centered card's content autoplays and loops as soon as it is
  centered (`CardContentViewController.cardDidBecomeCentered`); it pauses when it
  leaves center, keeping position. Downloader's unsaved pasteboard preview is the
  deliberate exception: it stays paused until the user explicitly taps Play.
- **Tap** the centered card: pause/play. **Horizontal drag inside** it: scrubs the
  playback timestamp (one card-width ≈ full duration). While a Downloader
  video is actively being scrubbed, a transient
  `MoonHorizonProgressBar` sits just below the card, against the black carousel
  background, and follows the seek position; it fades away when the drag ends.
  It shows only determinate progress and the head point—the traveling activity
  pulse remains exclusive to download progress. GIF scrubbing retains its
  existing gesture without showing the video-position bar.
  The card itself never pans.
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
  The Downloader opts into `autoplaysScrubPreviewContent`: as each thumbnail
  reaches the strip's center, the large overlay mounts that card's real content
  immediately and autoplays it using the carousel's current mute state
  (including looping videos and GIFs). Moving
  to another thumbnail stops and replaces that temporary preview player. On
  release, the selected preview controller is promoted into the centered card
  without replacing its player or timestamp, so playback continues smoothly;
  only the centered card's mute and optional Photos controls fade in. The
  Photos control opens that Photos-backed asset in the Photos app.
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
source URL) and a transient pasteboard pipeline. Privacy-safe probable-URL pattern
detection inserts a paste-icon placeholder at index zero without reading its value.
Paging onto it performs the user-initiated read, validates Downloader ownership,
and immediately stages the media to a one-hour temporary file while the card shows
moon-horizon progress. Completion replaces it with a normal image/GIF/video card
and a real thumbnail in the scrubber, but suppresses center autoplay. The first
explicit Play tap (or a still-image card tap) commits it to `SavedMediaStore`, the
shared reading list, and Photos. Changing the pasteboard or reaching the one-hour
deadline discards the unsaved file.

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

## Store plumbing (Downloader host)

`SavedMediaCardsViewController` keeps the grid's plumbing: cross-process Darwin
bridge, `.savedMediaChanged`/`.readingListChanged`/foreground/activation reloads,
expiry purge, Photos reconciliation (full `.authorized` only), long-press context
menu (Download / Share / Save to Photos / Archive / Delete), mark-opened on centering, and the
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
  Scrolling the strip shows the exact reader card that will be selected,
  including its current mode, content hierarchy, and saved reading position.
  The carousel prepares real card controllers only for chips intersecting the
  scrubber viewport, releases prepared controllers as they leave that window,
  and promotes the live preview controller directly into the centered slot on
  commit. Reader previews remain on the scroll reader's Phase-1 prefix: only
  enough text and inline images for the visible content window are laid out or
  loaded. Promotion of that same controller permanently lifts the primary gate
  and starts the seamless Phase-2 full-content swap. The preview therefore
  cannot swap to different content when the strip settles, while whole-article
  layout and image loading stay off the scrub path. A deep saved position still
  renders enough content up front to restore its actual viewport.
- EVERY mounted card (centered + both side peeks) embeds a full live
  `RabbitHoleReaderViewController` (`ReaderHostFactory.make`), laid out to the
  card's bounds — the card view IS the fullscreen reader view (one header, one
  layout for both states), and paging never shows a placeholder. The layer
  header is not a bar: back (inline-reader layers only) or Pasteboard (root
  layer when a URL is available) occupies top-left and read-aloud sits top-right.
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
  legible; scrolled content fades away as it approaches an edge. RSVP
  reserves the same run for its Words/Phrases switcher
  (`RSVPViewController.topContentInset`), so the switcher sits below the
  fade instead of dissolving into it.
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
  The card content drives it directionally from the embedded reader (KVO on
  its scroll views, re-swept via
  `RabbitHoleReaderViewController.onContentHierarchyChanged` when a dive/pop/
  mode switch swaps them, sampled synchronously so flicks aren't misread as
  settled): **scrolling down** past a small directional run (24pt, resetting
  on direction flips so jitter can't toggle it) fades the chrome away;
  **scrolling up — from anywhere in the article —** by one third of the visible
  card height fades it back in; reaching the top restores it immediately, and
  approaching the article bottom restores it when the content edge meets the
  resting card's future bottom edge. Tapping plain reader content also toggles
  immersion, while links and inline images retain their normal actions. During
  scroll immersion, a screen-level dissolve becomes opaque at the top edge of
  the persistent Settings/Share buttons so content never bleeds into their
  footer safe area. In **RSVP**, playing fades it away and pausing
  brings it back (`RSVPViewController.onPlaybackStateChanged`).
- **Long-press** on the centered card opens its Archive context menu. Archived
  article squares show favicon, title, and original save date; tapping opens the
  fully retained reader content; long-pressing opens a context menu with Unarchive
  and Share.
- The cards root has NO header bar.
- A new pasteboard URL is represented as a synthetic leading card (so it is
  visible as the left peek) and as a `doc.on.clipboard` mini-card in the scrubber.
  `UIPasteboard.detectPatterns(.probableWebURL)` is the only launch/foreground
  probe, so opening Luna does not read the value or raise a paste-permission
  prompt. Paging onto the placeholder (or tapping it when there are no normal
  cards) performs the actual read. A readable Reader-owned URL is fetched into a
  full, unsaved live reader card and receives normal title/favicon scrubber chrome;
  it persists only when reading activity dismisses the carousel chrome. The old
  top-left paste button is gone. Unsupported/invalid results become an “Invalid
  paste” card. A read taking at least 250 ms is treated only as a hint that a
  permission sheet was shown, enabling the inline tappable Settings guidance;
  fast failures simply say “Invalid URL.” The hint is never cached as permission
  state. The candidate disappears when the pasteboard changes, and a consumed
  change-count stays suppressed until the next change.
- Settings and Share flank the mini-card scrubber in Liquid Glass circles instead of
  consuming header space. Friends is reached from Settings. The card begins
  directly below the safe area, so the reader's own header pills own the top row.
- SceneDelegate's two `as? ReadingListViewController` casts now handle both
  roots (deep-link `openReader` → `openExternally(_:)`; friend prompt presents
  from whatever the root is). needsCaptcha cards route through the same
  archive.today modal flow as the old list.
