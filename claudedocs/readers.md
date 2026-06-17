# Readers

> **Location: `ReaderKit/`** — the entire reader stack lives in a `ReaderKit/`
> synchronized folder that is a member of the `Clip` (main app), `ClipShare`
> (share extension), and `Clip Action Extension` targets, so the share-sheet
> reader is the EXACT same code. ReaderKit is free of CloudKit/ARKit/camera: the
> camera (`EyeGazeWordTracker`) and the main-app social/CloudKit share stack
> (`AppReaderProviders`/`SendToFriendSheet`/`ReaderShareSheet`) stay main-app-only
> and are injected via `ReaderShareProviding` / `GazeTrackerFactory`
> (`ReaderKit/ReaderProviders.swift`). The share extension passes nil providers;
> the action extension injects a lightweight `ShareKit/ExtensionReaderShareProvider`
> (friend-share via the App Group queue, no CloudKit) so its reader has a working
> share button/footer (no eye tracking). SwiftSoup is linked to both extension
> targets too (they ingest the shared URL via `ArticleFetcher` + `ArticleExtractor`).
> ReaderKit also holds the models/helpers it needs: `ArticleContent`,
> `ReadingListItem`, `ReadingListStore`, `ReaderSettings`, `YouTubeURL`,
> `ClickDeepLink`, `NonTextualContent`.

THREE reading modes for extracted articles, with read-aloud, nested inline readers, position memory, and (device-only, main-app-only) eye tracking. Hosted by `ReaderKit/ReaderViewController.swift` — a container with a **3-way nav-bar segmented switcher** (icons via `ReaderKit/ReaderModeIcons`: `text.alignleft` scroll / a stylized "Abc" highlighted-text glyph for chunk-highlight / "Abc" with the RSVP focal reticule for speed) plus a **separate audio toggle** (speaker bar button) that turns read-aloud on/off for whichever mode is showing. It persists `lastReaderMode` per article AND globally (`ReaderSettings.lastReaderMode`) — a new article with no per-article preference opens in the global last-used mode. Changing mode/audio rebuilds the child VC. Tracks read state (marks `.opened` on open; children call back `onFinishedReading` → `.read`).

**Position carry-over across mode switches** (`ReaderPositionTracking` protocol, `ReaderProviders.swift`): before tearing the outgoing child down, the host reads its `currentReadingWordIndex` and passes it as `resumeWordIndex` to the next child. Scroll plain-mode reports the gaze `estimatedWordIndex` (when eye tracking is active) else the first FULLY-visible word (`firstFullyVisibleWordIndex` — first line not clipped by the top edge); entering scroll mode scrolls that word to 25% from the top (`scrollWord(_:toFractionFromTop:)`, clamped, no overscroll). Highlight/audio start playback at the word (follow-scroll centers it). RSVP reports/accepts its `currentIndex`. First open (no switch) keeps the persisted defaults (lastScrollOffset / lastWordIndex).

**Audio session (PiP-safe)**: the silent speed readers NEVER instantiate a speech synthesizer or touch `AVAudioSession` (instantiating `AVSpeechSynthesizer` can interrupt Picture-in-Picture). RSVP's synthesizer is `lazy` (read-aloud only); `.playback` is activated only when read-aloud actually plays, and deactivated with `.notifyOthersOnDeactivation` on pause/exit (in both RSVP and `SpeechController`) so other audio/PiP RESUMES.

- **Scroll**: plain scrolling text (audio off) or read-aloud word-follow (audio on).
- **Highlight** (`Clip/Reader/ChunkHighlightController.swift` + `ChunkPlanner.swift`): auto-advancing chunk highlight over the scrolling text — no audio by default, footer play/pause/skip/speed, auto-centering. Chunking follows speed-reading practice (≤4 words / ≤24 chars per chunk, broken at sentence/clause boundaries); per-chunk duration = wordCount·60/WPM × length × pause factor. Turning audio on in this mode reads aloud (word-follow) instead.
- **RSVP**: centered one-word display (audio off = WPM timer, audio on = sentence TTS).

The scroll reader (`ScrollReaderViewController`) backs both Scroll and Highlight via `init(autoHighlight:audioEnabled:)`: audio → `SpeechController`; else autoHighlight → `ChunkHighlightController`; else plain. The footer routes play/pause/skip/speed to whichever engine is active.

## Scroll reader (+ split-web link handling)

- `Clip/Reader/ScrollReaderViewController.swift` — full-screen `UITextView`, serif type, attributed text from `ArticleTextRenderer`. Link taps intercepted via `textView(_:primaryActionFor:defaultAction:)` → opens the split instead of Safari. Bolt button → RSVP.
- `Clip/Reader/ArticleTextRenderer.swift` — blocks → `NSAttributedString` (title, headings, quotes, bullets, `.link` attributes from stored UTF-16 ranges).
- `ReaderKit/SplitWebOverlayViewController.swift` — the split inline reader. All
  motion is one `apply(progress:)` (0 = open, 1 = closed onto the cut line): the
  card interpolates between its open frame and a zero-height sliver at `cutY`, and
  the two snapshot peeks are pinned FLUSH to the card's top/bottom edges (derived
  from the card frame) so there's never a gap for the live reader to ghost
  through. Open animates 1→0 starting from the link's actual on-screen position;
  dismiss animates 0→1 (so the rejoined screen matches the reader underneath); an
  interactive peek drag maps to progress and, once it hits 1, dismisses and never
  re-grows. A liquid-glass header (`.systemThickMaterial`) holds the ✕ + save with
  the content scrolling under it (top content inset). The chevron is blue and
  straddles the card's bottom edge. When the linked page is article-like (probed
  via `ArticleFetcher`+`ArticleExtractor`) the card shows the app reader's text
  (`ArticleTextRenderer`) instead of the web view; a link in that reader falls
  back to the web view in place. Also backs the RSVP link pill (nil peeks → grows
  from the screen center over a dim backdrop).
  <!-- older single-outer-scroll description follows; superseded -->
- `ReaderKit/SplitWebOverlayViewController.swift` (legacy notes) — On a link tap the reader is snapshotted at the TOP of the link's line: the part above parks as a one-line peek at the top, the link's line as a one-line peek at the bottom (both are `resizableSnapshotView` halves), and an inset rounded liquid-glass card (`ReaderDepth.backgroundColor(0)`, 14pt inset, 26pt corners, hairline border + sibling drop-shadow) grows out from the cut to fill the space between them (`animateOpen`, spring). The card's `WKWebView` (WebJunkBlocker applied) scrolls AND navigates INDEPENDENTLY — its gestures never reach the reader. Three dismissals, all animating the card's height to zero from its center while the peeks rejoin (`applyCompression(progress)` → `animateDismiss`): (1) the ✕ at the card's top-left, (2) the `chevron.compact.down` on the card's bottom edge, (3) an interactive `UIPanGestureRecognizer` on either peek — the card loses height equal to TWICE the drag distance (`progress = 2·|dy| / openHeight`), dismissing at progress ≥ 0.5 or a fast flick. A `square.and.arrow.down` save button (→ checkmark) sits top-right when a `shareProvider` is present. Presented `.overFullScreen` (no transition; the grow animation is the entrance). The same VC also backs the RSVP link pill, presented with nil peeks + `lineTopScreen = midY` so the card grows from the screen center. `onDismiss` re-asserts the reader's offset (it never moved).

## RSVP reader (ReadMaxx-style)

- `Clip/Reader/RSVPEngine.swift` — pure logic, unit-tested. Tokenizes blocks into `RSVPWord`s. ORP index by length: 1→0, 2–5→1, 6–9→2, 10+→3. `duration(at:wpm:)` = 60/wpm × length factor (≤5: 1.0, 6–9: 1.3, 10+: 1.6) × pause factor (paragraph end 2.5, sentence end 1.8, clause `,;:` 1.3).
- `Clip/Reader/RSVPViewController.swift` — word positioned so the ORP letter (tinted in the reading accent) sits on a fixed focal column (40% width) behind a **liquid-glass focus capsule** (`GlassStyle.focusPill()` — `UIGlassEffect` capsule, subtle indigo tint; replaced the old red guideline notches/hairlines); tap = play/pause; scrubber (accent tint, pauses while scrubbing); ±25 wpm buttons (persisted via `ReaderSettings.baseWPM`, 100–900, default 300); "% · wpm" status; light haptic at sentence/paragraph ends; resume via `ReadingListItem.lastWordIndex` saved on pause/close.
- `Clip/Settings/ReaderSettings.swift` — base WPM in standard defaults (also adjustable in Settings screen slider).

## Header bar

The 3-mode switcher lives in an **inline header bar** at the top of the reader's
content (a `contentContainer` hosts the child reader below it), NOT in
`navigationItem.titleView` — so it doesn't slide right→left during push/pop. The
nav bar holds only the back button + audio/share. The share-extension reader has
no nav bar of its own beyond Done.

## Focus styling + end-of-article share

- **Accent is configurable**: `ReaderAccent` enum (blue default + red/green/
  purple/yellow/orange/teal/pink/indigo), stored in `ReaderSettings.accent`
  (App Group); `GlassStyle.readingAccent` returns it. Picked via Settings →
  Reader → Highlight Color.
- **RSVP focus = glass reticule**, not a pill: two `GlassStyle.reticuleMark()`
  glass capsules (accent-tinted) sit above and below the ORP letter at the
  focal column. Scroll/chunk highlight = inline text-background tint in the
  accent (a glass overlay would blur the words being read).
- **End-of-article share** (`Clip/Reader/ArticleShareView.swift`): separator + "Done reading? Share it." + Share button + one-tap "Send to <friend>" suggestion. The Share button → `ReaderShareProviding.presentShareSheet`. Scroll reader appends it below the text (subview positioned via a `contentSize` observer; `contentInset.bottom` reserved so it clears the floating footer); RSVP fades it in above the controls on finish.

## Reader share sheet (the share button) — Feature C

The reader's nav-bar/footer Share button routes through `ReaderShareProviding.presentShareSheet`. In the main app, `AppReaderShareProvider` presents `Clip/Social/ReaderShareSheet.swift` — a medium-detent `UISheetPresentationController` with up to four options: **Send to {suggested friend}** (one tap, shown only when a streak/semantic suggestion exists), **Send to a Friend…** (`SendToFriendSheet.presentFriendPicker`), **Share Link…** (`SendToFriendSheet.shareLink` — URL + `clickreader://` deep link), **Share eBook…** (`ArticleExportService.presentShareSheet`, see article-export.md). Rows are a pure `ReaderShareSheet.rows(…)` list (testable visibility/actions); tapping dismisses the sheet then runs the action. `SendToFriendSheet` keeps reusable `shareLink`/`presentFriendPicker`/`sendToFriend` pieces (its action-sheet `present(…)` still backs the reading-list row).

## Share-sheet reader experience

Fixed behavior: the **share extension** (`com.apple.share-services`) always saves + dismisses, for every URL. The **"Read in Click" action extension** (`com.apple.ui-services`) routes via `ShareViewController.presentSavedOrReader`:
- **Article URLs** → `ShareKit/ShareReaderViewController` fetches + extracts (`ArticleFetcher` + `ArticleExtractor`) and presents the **real** `ReaderViewController` with `gazeTrackerFactory: nil` but a lightweight **`ExtensionReaderShareProvider`** (Feature D) — so the end-of-article share affordance works: it offers a friend picker (friends read from the App Group via `ExtensionFriendsReader`; the send is QUEUED to `pendingFriendShares.json` via `PendingFriendShareWriter` for the main app to deliver — no CloudKit in the extension) plus a link share. No suggestion engine in the extension, so no one-tap suggested send. The action ext keeps its OWN last-used mode in `ShareKit/ActionReaderMode` (private `UserDefaults.standard`); `ReaderViewController(persistsModePreference:false, onModeChange:)` writes there, not the shared `ReaderSettings`. If fetch/extract fails, `presentFailure()` shows a red error state (warning glyph + message) with Done available.
- **Non-textual URLs** (YouTube; generalizes via `ReaderKit/NonTextualContent`) → saved, then `ShareKit/SavedNonTextualViewController`: a saved-confirmation badge (YouTube embeds still play inline) + Done — instead of running the text extractor. (No "Open in Click" — `extensionContext.open` didn't reliably leave the action extension, so it was removed; showing nothing beyond the confirmation is fine.)

All three reader modes, audio (foreground only), and the inline split-web link viewer work; a Done button exits the extension. Resume with no gaze starts from the first fully-visible word (`ScrollReaderViewController.firstFullyVisibleWordIndex`).

**Gaze highlight** (`ReaderSettings.highlightGazeWord`, Settings → Eye Tracking, opt-in): in plain scroll mode with eye tracking active, a 0.3s timer highlights the word the gaze tracker estimates you're reading (no auto-scroll).

**Deep links**: `clickreader://read?url=…` (`ClickDeepLink`) opens the app and loads that article in the reader (`SceneDelegate.openReader`). The in-app "Share Link…" shares this link. (A custom scheme opens the app only when installed; App-Store fallback would need a Universal Link.)

## Inline images

Extractor emits `.image` blocks (`imageURLString`) for article `<img>`s — token-exact junk filter (ad/tracking/logo/etc; substring matching would reject WordPress `/uploads/` URLs) and skips declared-tiny (<140 px), svg/gif. Ingestor downloads up to 8 (≤5 MB each) into the Articles dir (`imageFileName`); failed downloads drop the block. `ArticleTextRenderer` inlines them as `NSTextAttachment`s via ImageIO downsampling (never decodes full-size). RSVP ignores image blocks (no tokens).

## Tests

`ClipTests/RSVPEngineTests.swift` (ORP, timing, flags).

## Reader appearance (Settings)

`ReaderSettings`: fontScale (S/M/L/XL segmented), useSerifFont, showReadingTime, showReadingProgress — renderer reads font settings at render time; readers persist `readingProgress` (max of scroll depth / RSVP fraction).

## Read-aloud (Clip/Reader/SpeechController.swift)

AVSpeechSynthesizer, block-per-utterance. Scroll reader: floating glass speaker button → footer controls (paragraph skip ±, play/pause, rate cycle 0.8/1/1.2/1.5×); current word highlighted and auto-centered (follow disabled when the user drags, re-enabled on control taps); resume position (`lastSpokenWordIndex`) persisted and highlighted on open until first user scroll. Background playback: `UIBackgroundModes audio`, AVAudioSession `.playback/.spokenAudio`, MPRemoteCommandCenter + NowPlaying. RSVP: speaker toggle speaks whole SENTENCES (natural prosody, normal pace) and flashes each word via `willSpeakRangeOfSpeechString` offsets; WPM ignored. All TTS uses `SpeechVoice.best` (premium > enhanced > default on-device voice; simulator forces default — high-quality assets stall synthesis there). No newer synthesis API exists in the iOS 26/27 SDKs (AVSpeechSynthesizer remains the system API). Word indices shared via `Clip/Reader/WordMap.swift` (built from `RenderedArticle.blockTextRanges`; same tokenization as RSVPEngine).

## Inline reader content

The card is a single scrollable+navigable `WKWebView` (WebJunkBlocker strips junk/overlays); links inside it navigate the web view in place rather than recursing into more overlays. (Earlier builds extracted an article-like page into a nested viewport-floating text view; the current split model uses the web view directly so it can scroll and navigate independently — far simpler than the old single-outer-scroll viewport hack.) `ReaderKit/ReaderDepth.swift` still tints the card background to the reader's depth-0 color (dark-mode aware).

## Position memory & eye tracking

`lastScrollOffset` restored on open. `Clip/Reader/EyeGazeWordTracker.swift` (ARKit face tracking, TrueDepth only — nil on simulator): forward-biased word estimate (small forward steps; far jumps only after ~12 steady samples in a new region), persisted to `eyeTrackedWordIndex` on close. First-ever audio playback and first-ever RSVP entry start from the gaze estimate. Settings toggle disables tracking and `clearAllEyeTracking()` nils all stored estimates. Camera usage string in Info.plist.

## TextKit note

Reader AND all overlay slices force TextKit 1 at creation (`_ = textView.layoutManager` before text is set): a mid-session TK2→TK1 flip re-breaks lines and visibly shifts text. Slices re-assert driven offsets post-install and on scroll (UITextView clamps programmatic offsets against a stale contentSize on its first layout pass).
