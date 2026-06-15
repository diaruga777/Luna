# Readers

THREE reading modes for extracted articles, with read-aloud, nested inline readers, position memory, and (device-only) eye tracking. Hosted by `Clip/Reader/ReaderViewController.swift` — a container with a **3-way nav-bar segmented switcher** (`text.alignleft` scroll / `highlighter` highlight / `bolt.fill` RSVP) plus a **separate audio toggle** (speaker bar button) that turns read-aloud on/off for whichever mode is showing. It persists `lastReaderMode` per article AND globally (`ReaderSettings.lastReaderMode`) — a new article with no per-article preference opens in the global last-used mode. Changing mode/audio rebuilds the child VC. Tracks read state (marks `.opened` on open; children call back `onFinishedReading` → `.read`).

- **Scroll**: plain scrolling text (audio off) or read-aloud word-follow (audio on).
- **Highlight** (`Clip/Reader/ChunkHighlightController.swift` + `ChunkPlanner.swift`): auto-advancing chunk highlight over the scrolling text — no audio by default, footer play/pause/skip/speed, auto-centering. Chunking follows speed-reading practice (≤4 words / ≤24 chars per chunk, broken at sentence/clause boundaries); per-chunk duration = wordCount·60/WPM × length × pause factor. Turning audio on in this mode reads aloud (word-follow) instead.
- **RSVP**: centered one-word display (audio off = WPM timer, audio on = sentence TTS).

The scroll reader (`ScrollReaderViewController`) backs both Scroll and Highlight via `init(autoHighlight:audioEnabled:)`: audio → `SpeechController`; else autoHighlight → `ChunkHighlightController`; else plain. The footer routes play/pause/skip/speed to whichever engine is active.

## Scroll reader (+ split-web link handling)

- `Clip/Reader/ScrollReaderViewController.swift` — full-screen `UITextView`, serif type, attributed text from `ArticleTextRenderer`. Link taps intercepted via `textView(_:primaryActionFor:defaultAction:)` → opens the split instead of Safari. Bolt button → RSVP.
- `Clip/Reader/ArticleTextRenderer.swift` — blocks → `NSAttributedString` (title, headings, quotes, bullets, `.link` attributes from stored UTF-16 ranges).
- `Clip/Reader/SplitWebOverlayViewController.swift` — the "cut" interaction. Layout is ONE outer `UIScrollView` stacked: peek strip (96 pt, ENDS with the full line containing the tapped link) → top border band (accent rule + notch at the link's x) → `WKWebView` at full content height (interaction disabled so the outer scroll owns all gestures; height via KVO, capped 8000 pt) → bottom border band (mirrored notch) → tail (STARTS with that same link line — the line is replicated on both sides, link text highlighted in both). Part-open animation runs in `viewDidAppear` using SNAPSHOTS of the reader taken before presenting (zero text layout up front). The slices are viewport-sized SCROLLABLE text views (interaction off) with driven content offsets — lazy layout, so the whole article is never laid out inside the overlay; the tail's viewport floats over the on-screen part of the tail region (`updateTailViewport`). The reader force-lays-out its own text ~0.4s after load so later geometry/restore ops never stall. ✕ runs the reverse animation by reparenting the live slices and closing them over the web frame. `WebJunkBlocker` (Clip/Reader/WebJunkBlocker.swift) attaches a css-display-none content rule list + script/domain blocks and injects a cleanup script that removes large fixed/sticky overlays (donation/consent nags) and unlocks body scrolling. Scrolling past the frame keeps scrolling (momentum intact); the seamless swap to the reader happens when the scroll SETTLES past webEnd (or on next touch-down) — scrolling back up then shows continuous article text. Web height changes from KVO are deferred while dragging/decelerating (offset-compensated when applied) so text never jumps. The reader's `restoreScroll` forces `ensureLayout` before clamping (lazy text layout otherwise breaks scrolling after dismissal).

## RSVP reader (ReadMaxx-style)

- `Clip/Reader/RSVPEngine.swift` — pure logic, unit-tested. Tokenizes blocks into `RSVPWord`s. ORP index by length: 1→0, 2–5→1, 6–9→2, 10+→3. `duration(at:wpm:)` = 60/wpm × length factor (≤5: 1.0, 6–9: 1.3, 10+: 1.6) × pause factor (paragraph end 2.5, sentence end 1.8, clause `,;:` 1.3).
- `Clip/Reader/RSVPViewController.swift` — word positioned so the ORP letter (tinted in the reading accent) sits on a fixed focal column (40% width) behind a **liquid-glass focus capsule** (`GlassStyle.focusPill()` — `UIGlassEffect` capsule, subtle indigo tint; replaced the old red guideline notches/hairlines); tap = play/pause; scrubber (accent tint, pauses while scrubbing); ±25 wpm buttons (persisted via `ReaderSettings.baseWPM`, 100–900, default 300); "% · wpm" status; light haptic at sentence/paragraph ends; resume via `ReadingListItem.lastWordIndex` saved on pause/close.
- `Clip/Settings/ReaderSettings.swift` — base WPM in standard defaults (also adjustable in Settings screen slider).

## Focus styling + end-of-article share

- `GlassStyle.readingAccent` (systemIndigo, matching the app icon) is the shared reader accent (replaced red). Scroll/chunk highlight = inline text-background tint in that accent (a glass overlay would blur the words); RSVP = glass capsule behind the opaque on-top word.
- **End-of-article share** (`Clip/Reader/ArticleShareView.swift`): separator + "Done reading? Share it." + Share button + one-tap "Send to <friend>" suggestion (`ShareSuggestionStore.suggestedFriend(forURLString:)` → `SendToFriendSheet.sendToFriend`). Scroll reader appends it below the text (subview positioned via a `contentSize` observer; `contentInset.bottom` reserved so it clears the floating footer); RSVP fades it in above the controls on finish.

## Share-sheet reader experience

`ShareSheetExperience` (off/reader/rsvp/chunk, App Group default, `Settings → Reader → Share Sheet`). When not off, sharing a link into Click saves it AND presents `ClipShare/ShareReaderViewController` — a **self-contained** single-article reader (WebKit + UIKit only; independent of this reader stack, which pulls in CloudKit/camera/SwiftSoup): `reader` = WKWebView; `rsvp`/`chunk` extract `document.body.innerText` and run a compact speed reader. Done to exit; no access to the rest of the app. See `save-link-intent.md`.

## Inline images

Extractor emits `.image` blocks (`imageURLString`) for article `<img>`s — token-exact junk filter (ad/tracking/logo/etc; substring matching would reject WordPress `/uploads/` URLs) and skips declared-tiny (<140 px), svg/gif. Ingestor downloads up to 8 (≤5 MB each) into the Articles dir (`imageFileName`); failed downloads drop the block. `ArticleTextRenderer` inlines them as `NSTextAttachment`s via ImageIO downsampling (never decodes full-size). RSVP ignores image blocks (no tokens).

## Tests

`ClipTests/RSVPEngineTests.swift` (ORP, timing, flags).

## Reader appearance (Settings)

`ReaderSettings`: fontScale (S/M/L/XL segmented), useSerifFont, showReadingTime, showReadingProgress — renderer reads font settings at render time; readers persist `readingProgress` (max of scroll depth / RSVP fraction).

## Read-aloud (Clip/Reader/SpeechController.swift)

AVSpeechSynthesizer, block-per-utterance. Scroll reader: floating glass speaker button → footer controls (paragraph skip ±, play/pause, rate cycle 0.8/1/1.2/1.5×); current word highlighted and auto-centered (follow disabled when the user drags, re-enabled on control taps); resume position (`lastSpokenWordIndex`) persisted and highlighted on open until first user scroll. Background playback: `UIBackgroundModes audio`, AVAudioSession `.playback/.spokenAudio`, MPRemoteCommandCenter + NowPlaying. RSVP: speaker toggle speaks whole SENTENCES (natural prosody, normal pace) and flashes each word via `willSpeakRangeOfSpeechString` offsets; WPM ignored. All TTS uses `SpeechVoice.best` (premium > enhanced > default on-device voice; simulator forces default — high-quality assets stall synthesis there). No newer synthesis API exists in the iOS 26/27 SDKs (AVSpeechSynthesizer remains the system API). Word indices shared via `Clip/Reader/WordMap.swift` (built from `RenderedArticle.blockTextRanges`; same tokenization as RSVPEngine).

## Nested inline readers

Border treatment: the middle frame is an inset rounded card (10pt inset, 22pt continuous corners) with floating glass chevron chips at the tapped link's x on both edges (GlassStyle.barEffect). The split overlay probes the tapped link concurrently with the web load (`ArticleFetcher` + `ArticleExtractor`); if article-like (≥1200 chars across ≥5 text blocks) the web view is swapped for a nested reader (viewport-floating text view with userInteraction OFF — UIScrollView silently re-enables a disabled pan recognizer, so anything less makes the nested reader scroll independently of the outer view; link taps come from a recognizer on the CONTAINER, resolved manually via layoutManager). Nested links recurse: each level presents another overlay with `depth+1` and a slightly lighter background (`Clip/Reader/ReaderDepth.swift`, dark: 0/0.07/0.12/0.16/0.20 white; light mirrored). Non-articles keep the web view.

## Position memory & eye tracking

`lastScrollOffset` restored on open. `Clip/Reader/EyeGazeWordTracker.swift` (ARKit face tracking, TrueDepth only — nil on simulator): forward-biased word estimate (small forward steps; far jumps only after ~12 steady samples in a new region), persisted to `eyeTrackedWordIndex` on close. First-ever audio playback and first-ever RSVP entry start from the gaze estimate. Settings toggle disables tracking and `clearAllEyeTracking()` nils all stored estimates. Camera usage string in Info.plist.

## TextKit note

Reader AND all overlay slices force TextKit 1 at creation (`_ = textView.layoutManager` before text is set): a mid-session TK2→TK1 flip re-breaks lines and visibly shifts text. Slices re-assert driven offsets post-install and on scroll (UITextView clamps programmatic offsets against a stale contentSize on its first layout pass).
