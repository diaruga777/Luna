# Robust Audio Playback — Implementation Plan

Status: **implementation in progress — Phases 1 and 2 landed** (engine core; playback
center + Now Playing/remote commands + session policy + position persistence +
`AudioSettings` + AppDelegate wiring incl. the queue provider). Phase 3 (UI), Phase 4
(trimming), and Phase 5 (integration) remain. This doc is the working plan; when the
feature lands, rewrite it as the feature doc (per CLAUDE.md, `claudedocs/` stays current).

## What we're building

Podcasts-grade read-aloud for Luna Reader:

1. **Playback engine rebuilt for reliability** — offline speech rendering
   (`AVSpeechSynthesizer.write`) into PCM buffers played through a long-lived
   `AVAudioEngine`, replacing live `speak()` (documented to stall/cut off in background).
   Apple voices only (Enhanced/Premium nudge stays); **no third-party neural TTS** —
   decision: skipped entirely, do not build a pluggable-engine abstraction.
2. **Autoplay next article** — on finish, mark read, soft chime, "Now Reading —
   <title>" announcement (same voice, **always at 1.0× rate** regardless of the user's
   playback speed), chime again, next article body. Queue rule: **top-most item in the
   current Reader-surface list order whose `readState == .unopened`** and which is a
   readable article (has extracted `ArticleContent` text; skip videos/products/paywalled
   stubs), excluding the item that just played. Opened-but-unfinished items are NOT
   auto-queued (explicit product decision). When no next item: a "final"-sounding chime,
   playback ends. Persisted setting to disable autoplay (default ON).
3. **Persistent mini-player** — window-level footer that survives navigation
   (reading list ↔ reader ↔ settings) and modal overlays; melds with RSVP controls;
   thumbnail + title + play controls + autoplay toggle + `MoonHorizonProgressBar`.
   Browsing another article does NOT switch playback; tapping play in that reader (or
   the mini-player's article row) does.
4. **Background playback** — Now Playing + remote commands (skip +30s/−15s, lock-screen
   scrub), AirPods gestures, resume-after-minutes (Now Playing candidacy), interruption
   & route-change handling, cold-relaunch restore.
5. **Audio-specific trimming** — the spoken text is a *subset* of the visual text.
   Deterministic heuristics always run; an optional FoundationModels pass (on-device,
   iOS 26+) classifies borderline paragraphs **by index** (never rewrites prose).
   Persisted setting to disable the LLM pass (default ON). Heuristic fallback on any
   LLM unavailability/error. Scripts are built **opportunistically as soon as an article
   is saved** (some trimming targets sit at the very start — byline/metadata — so
   waiting until playback would delay start-of-audio), not lazily at first play.
   Confidence is positional: trimming at the **start or end** of an article is
   considered less error-prone than trimming the middle, and removing a large fraction
   of the total length is inherently risky (capped).

## Existing code to build on (verified file paths)

- `LunaLibraries/Sources/LunaReaderUI/SpeechController.swift` — current engine (live
  `speak()`, word highlighting via `willSpeakRangeOfSpeechString`, paragraph skip, rate
  cycling, MPNowPlaying/MPRemoteCommand wiring). Being superseded in-app; **keep it
  working for the Share/Action extensions** (they link `LunaShareSurface` → `LunaReaderUI`
  and must not gain background-audio machinery).
- `LunaLibraries/Sources/LunaReaderUI/SpeechEngine.swift` — `BasicSpeechEngine` /
  `AppleEnhancedEngine` voice selection; reuse the voice-resolution logic.
- `LunaLibraries/Sources/LunaReaderUI/ReaderAudioSession.swift` — the AVAudioSession
  choke point (`.playback`/`.spokenAudio`). The new session coordinator replaces/extends it.
- `LunaLibraries/Sources/LunaReaderUI/VoiceModelStore.swift` — App-Group UserDefaults
  pattern (also `LunaDesignSystem/ReaderSettings.swift`) — copy this pattern for `AudioSettings`.
- `LunaLibraries/Sources/LunaDesignSystem/MoonHorizonProgress.swift` —
  `MoonHorizonProgressBar` (UIKit) — reuse as the mini-player progress indicator.
- `LunaLibraries/Sources/LunaStorage/ReadingListStore.swift` — `markFinishedReading(_:)`,
  `markReadState(_:for:)`, `content(for:)`, `.readingListChanged` notification (the
  reading list already live-reloads on any store mutation — mark-read during playback
  updates the list for free). `ReadingListItem.lastSpokenWordIndex` already exists.
- `Luna/SceneDelegate.swift` — root is `UINavigationController(rootViewController:
  ReadingListViewController(surface:))`; `showMainUI()` + `installDotMatrixTransitions()`.
  Mini-player attaches at window level (see Phase 3).
- Reader shells: `RabbitHoleReaderViewController`/`RabbitHoleLayerViewController` (main
  flow; `configureForReuse` currently destroys speech — must stop doing that) and
  `ReaderViewController` (Catch-Up + share extension). `ScrollReaderViewController`
  (`configureFooter()` ~line 733, the current in-reader audio footer — replaced in-app)
  and `RSVPViewController` (own per-sentence synthesizer in speech mode — reroute to the
  shared center; silent RSVP untouched).
- `LunaLibraries/Sources/LunaHTMLClassification/ArticleExtractor.swift` — existing
  strip-selectors/terminator heuristics; the audio trimming pass is a NEW post-extraction
  step over `ArticleContent`, it does not modify the extractor.
- `Luna/Info.plist` already has `UIBackgroundModes: [audio]`.

## Architecture

New SwiftPM module **`LunaAudioPlayback`** in `LunaLibraries/Package.swift`.
Dependencies: `LunaModels`, `LunaAppConfig`, `LunaStorage`, `LunaReaderEngine`,
`LunaDesignSystem`. `LunaReaderUI` gains a dependency on it. Swift 5 language mode;
public API needs explicit `public` + `public init`s. Bundle tone resources in the module.

### Components

**`SpeechRenderer`** — offline synthesis. For each text block:
`AVSpeechSynthesizer.write(_:toBufferCallback:)` → normalize every `AVAudioPCMBuffer`
with `AVAudioConverter` to one canonical float32 format (do NOT assume the synthesizer's
format matches the mixer; connect nodes using the canonical format). Capture word
timings: `willSpeakRangeOfSpeechString` fires during `write` — map each word range to a
sample offset within the rendered segment. **Verify this on-sim early**; if callbacks
don't fire during offline write, fall back to block-level timing (resume/highlight per
block, still fine). Render at the utterance's natural default rate; playback speed is
applied downstream by time-pitch. Output type: `RenderedSegment { blockIndex, buffers,
wordMarkers: [(range: Range<Int> /* word index in block */, sampleOffset)] , duration }`.

**`ArticleAudioEngine`** — long-lived `AVAudioEngine`: `AVAudioPlayerNode` →
`AVAudioUnitTimePitch` → `mainMixerNode`. User playback rate = `timePitch.rate`
(so rendered audio never needs re-synthesis on rate change; announcements pin
`timePitch.rate = 1.0` for their segments then restore). Rolling render window: keep
~2 blocks rendered ahead of the playhead (bounds memory/battery for hour-long articles).
Tones are short PCM buffers (decoded once from bundled `.caf`) scheduled on the same
player node between segments — sample-accurate sequencing, no second audio session.
Playhead from the player node's sample time (accurate elapsed), not synthesis callbacks.
Duration estimate: rendered-so-far actual + remaining-words × running avg sec/word
(updates as rendering proceeds); good enough for the scrubber and Now Playing.

**`AudioPlaybackCenter`** — the app-wide singleton and single owner of playback.
State machine: `idle / playing(item) / announcing(next) / paused(item, resumable)`.
API: `play(item:content:script:fromWordIndex:)`, `togglePlayPause`, `seek(toFraction:)`,
`skipForwardParagraph/backwardParagraph` (in-app buttons, matching today's behavior),
`skip(bySeconds:)` (±30/−15 for system commands; map seconds → word index via avg
sec/word), `cycleRate`/`setRate`. Multicast observer protocol for UI: state, item
(title/thumbnail path), progress fraction, word events `(blockIndex, wordRangeInBlock)`
for reader highlighting. Autoplay chain on segment-queue completion:
`store.markFinishedReading(id)` → transition chime → announcement utterance
("Now Reading — <title>", same voice, 1.0×) → chime → next article's script; empty
queue → final chime → `idle`. Persist `(itemID, lastSpokenWordIndex, elapsedEstimate)`
to App-Group defaults every ~5 s while playing and on every pause/seek (also mirror
word index into `ReadingListItem.lastSpokenWordIndex` via the store on pause/finish,
throttled — one store write per pause, not per tick).

**`AudioQueueProvider`** — injected closure `() -> ReadingListItem?` installed by the
app shell (so the module doesn't depend on list sectioning): returns the top-most item
in the current Reader-surface ordering with `readState == .unopened`, readable article
content, not the currently playing item.

**`NowPlayingCoordinator`** — `MPNowPlayingInfoCenter.default()` +
`MPRemoteCommandCenter.shared()`. Commands registered **at app launch in AppDelegate**
(not lazily — required for background-relaunch delivery): play/pause/toggle,
`skipForwardCommand.preferredIntervals = [30]`, `skipBackwardCommand = [15]`,
`changePlaybackPositionCommand`. Info: title, author/source as artist, artwork from
`thumbnailFileName` (decode once per item), duration, elapsed, rate — push
elapsed+rate together atomically on every play/pause/seek; `playbackState` kept
accurate. On a remote play command with no live engine (cold background relaunch),
restore from the persisted App-Group state and resume silently.

**`AudioSessionCoordinator`** — `.playback` + `.spokenAudio`, no mixing options
(Podcasts semantics: we pause others, others pause us; nav prompts pause not duck us).
Observes `AVAudioSession.interruptionNotification` (pause on `.began` WITHOUT
deactivating; on `.ended` resume only if `.shouldResume`) and
`routeChangeNotification` (`.oldDeviceUnavailable` → pause, keep session active; never
auto-resume on `.newDeviceAvailable`). Activation: activate on play; on user pause,
deactivate with `.notifyOthersOnDeactivation` after a ~5 s grace, keeping Now Playing
info + command targets registered (that registration — not session activity — is what
keeps AirPods-press-to-resume working minutes later).

**`AudioScriptBuilder`** (trimming) — input `ArticleContent`, output
`AudioScript { spokenBlocks: [(blockIndex, text)] , totalWords }`.
- *Heuristic pass (always runs, pure, synchronous):* drop image blocks and
  caption-pattern text (`Photo:`, `Credit:`, `Image:`, trailing `/Getty Images`, `/AP`,
  `/Reuters`, `(Photo by …)`), high link-density blocks (links' text ≥ ~40% of block
  text), related-link markers (`READ MORE:`, `MORE:`, `ALSO READ:`, `RELATED:`, short
  ALL-CAPS lines), bylines/timestamps near the top (`^By [A-Z]…`, `Updated:`,
  `Published:`, `min read`), social-embed boilerplate (`View this post on Instagram`,
  `A post shared by`, `Sign up for`/newsletter lines), share prompts. Aggressive is OK —
  audio-only; the visual reader is untouched. **Positional confidence:** leading blocks
  (bylines, dateline/metadata, "X min read") and trailing blocks (related links, share
  prompts, newsletter signups, © boilerplate) may be trimmed on weaker signals —
  contiguous runs from either edge are the cheap, low-risk wins. Mid-article removals
  require a high-precision signal (exact caption/credit patterns, explicit `READ MORE:`
  markers, very high link density); borderline mid-article blocks are what the LLM pass
  is for, not the heuristics.
- *LLM refinement (optional, async):* `SystemLanguageModel.default.availability ==
  .available` AND `AudioSettings.isIntelligentTrimmingEnabled` AND foreground (or accept
  `rateLimited` → skip). Chunk the *surviving* blocks ~25 per call as a numbered list of
  first ~20 words each. `instructions:` carry the task contract ("identify numbers that
  are NOT main article prose — captions, related-link lists, ads, bylines, newsletter or
  share prompts; if unsure, do not include the index"); `prompt` is only the numbered
  list (keeps article text from being treated as instructions). Output via `@Generable
  struct AudioCleanupVerdict { let removeIndices: [Int] }`. Validate mechanically:
  in-range, unique, and reject any chunk verdict flagging > 50% of its blocks. The
  positional rule applies to the LLM too: accept edge-adjacent removals (indices that
  extend a contiguous trimmed run at the start/end) at face value, but require
  mid-article removals to look like the known junk categories (short block, or matches a
  weak version of a heuristic signal) — when in doubt, keep the block. **Global cap:**
  if combined heuristic + LLM removal exceeds ~50% of the article's total word count,
  something is wrong — discard the LLM verdicts and use the heuristic-only script; if
  heuristics ALONE exceed the cap, degrade further to only the highest-precision rules
  (image blocks, exact caption/credit patterns, explicit markers). Errors
  (`guardrailViolation` → permanent for this article, don't retry;
  `exceededContextWindowSize` → halve chunk and retry once; `rateLimited` → skip; any
  parse failure → skip) all degrade to the heuristic-only script. `prewarm()` when a
  playback session starts.
- *Cache & build timing:* persist the finished script as a sibling JSON of the item's
  content file (derive name from `contentFileName`, embed a `builderVersion` int — bump
  to invalidate). **Build opportunistically at save time, not at first playback**
  (trimming often targets the very start of an article — byline/metadata — so a
  playback-time build would delay audio start). Trigger: the MAIN APP observes
  `.readingListChanged` (plus a sweep on launch/foreground) and builds scripts for any
  readable article lacking a current-version script — this covers items saved in-app
  AND items saved via the Share/Action extensions or intents (the extensions must NEVER
  run the builder themselves: extension memory limits + FoundationModels constraints).
  Heuristics run immediately; the LLM refinement runs when available (foreground; a
  `rateLimited` background attempt just leaves the heuristic script in place and the
  next foreground sweep upgrades it). Playback-time build remains only as a last-resort
  fallback for an item that somehow has no script; during playback, the NEXT queue
  item's script is verified/prefetched the same way.
- FoundationModels is imported only inside this file-set with availability guards; the
  heuristics have zero FoundationModels dependency.

### UI

**`AudioMiniPlayerView` + window-level host.** In `SceneDelegate`, wrap the root nav
controller in a container `UIViewController` (new `MiniPlayerHostViewController` in the
app shell) that becomes `window.rootViewController`: nav controller as a child filling
the view, mini-player pinned above the bottom safe area. Must not break
`installDotMatrixTransitions()` (called in `scene(_:willConnectTo:)` and `showMainUI()`
— re-point whatever it installs on to the nav controller inside the container). Hidden
when `idle`; animates in on first play; persists across pushes/pops and — because it's
at window level, above `rootViewController`'s subtree but below presented VCs — decide
during implementation whether it should also float over `SplitWebOverlayViewController`
(acceptable either way; do what looks right, playback continues regardless).
Contents: thumbnail (reuse the reading-list decode approach), title, paragraph
back / play-pause / paragraph forward / rate button (today's controls), autoplay
toggle (bound to `AudioSettings.isAutoplayEnabled`), `MoonHorizonProgressBar` driven by
progress fraction (also acts as scrubber if easy — nice-to-have, not required in v1;
lock screen scrubbing is required). Tap anywhere else on the bar → navigate to the
playing article (push reader if not already showing it). Style: `GlassStyle.barEffect()`
like the current scroll-reader footer.

**RSVP meld.** RSVP's controls are bare glass circles in a `controlsStack` (no bar).
When RSVP is frontmost in speech mode, the mini-player slims down (progress bar +
autoplay toggle + title only) and docks directly above `controlsStack`, while RSVP's
existing circular play/skip buttons drive `AudioPlaybackCenter` instead of a private
synthesizer; word flashing driven by the center's word events. Silent RSVP (timer mode)
is unchanged and never shows the mini-player.

**Reader integration.** `ScrollReaderViewController` drops its private footer/
`SpeechController` in-app: the audio toggle routes to `AudioPlaybackCenter`; word
highlighting subscribes to center word events and applies only when the displayed
article == the playing item. `RabbitHoleLayerViewController.configureForReuse` must NOT
stop center playback. `ReaderViewController` (Catch-Up) same treatment. The share
extension keeps the legacy `SpeechController` path — the center is installed only by the
app shell (injected, like the existing `SocialMessageCenter.ingestHandler` pattern);
when the injection is absent the readers fall back to the legacy path.

**Settings.** `AudioSettings` enum in `LunaAudioPlayback` (App-Group UserDefaults, same
shape as `ReaderSettings`): `isAutoplayEnabled` (default true),
`isIntelligentTrimmingEnabled` (default true), `preferredRate`. New "Audio" category in
`Luna/Settings/SettingsViewController.swift` → `AudioSettingsScreen`
(`NavHeaderTableController` subclass like `ReaderSettingsScreen`): autoplay toggle,
"Clean up articles for listening (Apple Intelligence)" toggle with a footer explaining
the on-device model + fallback, link to the existing `VoiceSettingsScreen`.

**Tones.** `scripts/make_tones.py` (numpy sine synthesis + envelope, emit WAV, convert
with `afconvert` to `.caf`), checked in like `make_icons.py`. Three assets bundled as
`LunaAudioPlayback` resources: `ChimeTransition.caf` (soft, two ascending notes, ~0.8 s),
`ChimeFinal.caf` (resolved, e.g. three notes landing on the tonic, ~1.5 s — audibly
"done"). Keep them quiet (peak ~ −12 dBFS) and warm (sine + gentle harmonics).

## Phases (each = one implementation agent, sequential unless noted)

1. **Engine core** — module scaffold in `Package.swift`, tone script + assets,
   `SpeechRenderer`, `ArticleAudioEngine`, `AudioScript` model (heuristics stubbed to
   pass-through), unit tests for renderer plumbing (format conversion, marker mapping)
   using short synthesized utterances. Early spike: confirm `willSpeakRangeOfSpeechString`
   fires during `write()` on the iOS 26 sim; record the answer in code comments.
2. **Playback center + system integration** — `AudioPlaybackCenter`, queue provider
   hook, autoplay chain + announcements, `NowPlayingCoordinator`,
   `AudioSessionCoordinator`, persistence/cold-relaunch restore, `AudioSettings`,
   AppDelegate launch wiring. Unit tests: queue rule, state machine, persistence
   round-trip (store-backed pieces behind protocols where needed).
3. **UI** — mini-player + window host, reader/RSVP/RabbitHole integration, settings
   screen, live list behavior check. Snapshot tests where the suite's pattern fits.
4. **Trimming** (parallel with 3) — heuristics (unit-tested against fixture
   `ArticleContent`s), FoundationModels pass + validation + fallbacks, script cache +
   prefetch.
5. **Integration pass** — wire trimming into the center, full test-suite run
   (CLAUDE.md recipe: `DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app xcodebuild test
   -scheme Luna … DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO` on an iOS 26 sim), fix
   fallout (snapshot re-records only for intentional UI changes), update this doc into
   the final feature doc, update CLAUDE.md if workflows changed.

Commit in small logical chunks as each phase verifies (per CLAUDE.md agent workflow).

## Decisions log (from product owner, 2026-07-10)

- Neural TTS (Kokoro): **skipped entirely**; no pluggable-engine abstraction.
- Queue: top-most readable article with `readState == .unopened`; if none, autoplay
  stops (final chime). `.opened` items are not auto-queued (explicitly chosen over the
  "include opened" variant).
- Browsing while playing: playback continues; explicit play switches.
- Announcements: same voice as narration, always 1.0× rate (pin time-pitch to 1.0 for
  announcement segments).
- Trimming timing (added later same day): build audio scripts opportunistically at save
  time (main app, `.readingListChanged` observer + launch/foreground sweep), NOT lazily
  at first playback.
- Trimming risk model (same update): start/end trimming is less error-prone than
  mid-article trimming — edge runs may use weaker signals, middle removals need
  high-precision signals; removing a large fraction of total length is inherently
  risky — global ~50% cap with progressive degradation to conservative rule sets.
