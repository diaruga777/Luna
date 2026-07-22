# Readers

> **Location: `ReaderKit/`** — the entire reader stack lives in a `ReaderKit/`
> synchronized folder that is a member of the `Luna` (main app), `LunaShare`
> (share extension), and `Luna Action Extension` targets, so the share-sheet
> reader is the EXACT same code. ReaderKit is free of CloudKit: the main-app
> social/CloudKit share stack
> (`AppReaderProviders`/`SendToFriendSheet`/`ReaderShareSheet`) stays main-app-only
> and is injected via `ReaderShareProviding`
> (`ReaderKit/ReaderProviders.swift`). The share extension passes a nil provider;
> the action extension injects a lightweight `ShareKit/ExtensionReaderShareProvider`
> (friend-share via the App Group queue, no CloudKit) so its reader has a working
> share button/footer. SwiftSoup is linked to both extension
> targets too (they ingest the shared URL via `ArticleFetcher` + `ArticleExtractor`).
> ReaderKit also holds the models/helpers it needs: `ArticleContent`,
> `LunaDeepLink`, `NonTextualContent`.

TWO reading modes for extracted articles, with read-aloud, nested inline readers, and position memory. Hosted by `ReaderKit/ReaderViewController.swift` — a container with a segmented switcher (icons via `ReaderKit/ReaderModeIcons`: `doc.richtext` for the extracted scroll reader / `forward.fill` for RSVP speed reading / a latitude-longitude `globe` for Original) plus a **separate audio toggle** that turns read-aloud on/off for whichever mode is showing. At the Reader card root, the switcher occupies the bottom-center only while card chrome is dismissed, replacing the mini carousel with a short translation + fade; standalone and extension hosts retain their own inline/nav placement. The retired standalone **chunk-highlight ("highlight") mode now lives as the RSVP reader's "Phrases" sub-mode** (see below); a persisted `.highlight` reader mode resolves to RSVP opened in Phrases (`ReaderViewController.opensRSVPInPhrases`, one-shot; `ReaderSettings.lastReaderMode` also maps the legacy value). A third **Original** segment (a locally saved `.webarchive` snapshot or an imported source document) is appended **only when the save actually has one** — `availableModes = baseModes + (ReadingListStore.hasOriginalSource(for:) ? [.original] : [])`. Saves with no real web page (mail/email imports — no web archive AND no source file) therefore never show Original (test: `ReadingListStoreTests.testEmailSaveHasNoOriginalSource`). It persists `lastReaderMode` per article AND globally (`ReaderSettings.lastReaderMode`) — a new article with no per-article preference opens in the global last-used mode. Changing mode/audio replaces the active child directly. RabbitHole layers create and attach only the selected reader child; switching modes removes that child and installs the requested one without keeping hidden reader views in the hierarchy. Scroll readers begin their full-content load as soon as they become visible. Tracks read state (marks `.opened` on open; children call back `onFinishedReading` → `.read`). Reaching the end never dismisses the reader: it springs in a temporary green check below scroll content or above the RSVP focus, whose tap expands “Finished reading, sending to archive” (shown automatically the first time per app install). Completion persists `pendingArchiveAt`; the card remains active for the foreground session, then the Reader app promotes that timestamp to `archivedAt` on background, or during the next cold launch after a force-quit. Scrolling/paging back does not retract a completion. A **floating glass share button** (bottom-right) lifts to clear that mode's footer (`floatingShareBottomInset(for:audioOn:)` — scroll mode only reserves room when read-aloud is on), and fades out while the end-of-article share footer is scrolled into view (`ScrollReaderViewController.onShareFooterVisibilityChanged`), fading back in otherwise.

**Position carry-over across mode switches** (`ReaderPositionTracking` protocol, `ReaderProviders.swift`): before tearing the outgoing child down, the host reads its `currentReadingWordIndex` and passes it as `resumeWordIndex` to the next child. Scroll plain-mode's reported index is **gated so opening/closing alone never moves the carried position** — the bug was recomputing `firstFullyVisibleWordIndex` on every switch, which drifted the index even when the user did nothing. The decision is a PURE, unit-tested function (`ReaderResumePositionResolver.reportedWordIndex(resumeIndex:scrolledPastThreshold:firstFullyVisibleIndex:)`, `ReaderKit/ReaderResumePositionResolver.swift`): the scroll reader records the content offset at open and reports the freshly-computed first FULLY-visible word (`firstFullyVisibleWordIndex` — first line not clipped by the top edge) ONLY if the user scrolled past a threshold (`scrolledPastThresholdPoints = 44pt` from the open offset); else it returns the incoming `resumeWordIndex` UNCHANGED (a no-op). (Active read-aloud / chunk playback still reports the live playback word. A FRESH open with no carried index — straight from the list — has no position to protect, so it reports the first-visible word so the first switch resumes correctly.) Entering scroll mode scrolls the carried word to 25% from the top (`scrollWord(_:toFractionFromTop:)`, clamped, no overscroll). Highlight/audio start playback at the word (follow-scroll centers it). RSVP reports/accepts its `currentIndex`. First open (no switch) keeps the persisted defaults (lastScrollOffset / lastWordIndex). Tests: `ReaderResumePositionResolverTests`.

**Audio session (PiP-safe)**: the silent speed readers NEVER instantiate a speech synthesizer or touch `AVAudioSession` (instantiating `AVSpeechSynthesizer` can interrupt Picture-in-Picture). RSVP's synthesizer is `lazy` (read-aloud only); `.playback` is activated only when read-aloud actually plays, and deactivated with `.notifyOthersOnDeactivation` on pause/exit (in both RSVP and `SpeechController`) so other audio/PiP RESUMES.

- **Scroll**: plain scrolling text (audio off) or read-aloud word-follow (audio on).
- **RSVP** (`ReaderKit/RSVPViewController.swift`): a centered speed reader with a **Words/Phrases sub-segmented control** sitting just below the top-level switcher (`subModeControl`, persisted in `ReaderSettings.rsvpMode`). Both sub-modes share the focal-word index (switching keeps your place), the scrubber / ±25-word skip / ±25 wpm controls, and read-aloud.
  - **Words**: the classic one-word-at-a-time display on the focal column with the ORP letter tinted, glass reticule marks above/below, word-length-aware timing (`RSVPEngine`). Context shows only while paused.
  - **Phrases**: a whole phrase shown over **two lines** in a glass reticule panel (`GlassStyle.focusPanel()`) in a **smaller proportional font** (`makePhraseFont`), with the surrounding prose **always visible above and below and updating as the phrase advances**. Phrase grouping + per-phrase timing come from `ReaderKit/ChunkPlanner.swift` driven by `ReaderKit/ReadingHeuristics.swift` (best-practice chunking: break at sentence/clause boundaries and before phrase-starting prepositions/conjunctions, never end a chunk on a determiner/preposition; dwell longer on long/complex/numeric words, skim function words). With read-aloud on, whole sentences are spoken and the **currently-spoken word is highlighted within the displayed phrase** (the phrase follows the speech word-to-word).

The Reader carousel gives every card a stable title region using the normal 30pt
reader-title font and the saved page's asynchronously cached favicon (a globe while
loading). Scroll and Original/web-archive modes own two pixel-identical copies: a
permanent copy in the scroll view's top content-inset region and a pinned card copy.
At the exact top the pinned copy is hidden, revealing the in-content copy beneath it;
after scrolling, the pinned copy is visible only while card chrome is surfaced. The
top inset never changes during either transition, so hiding chrome cannot move the
reader or its content offset. Both copies' backgrounds begin at the card's top edge,
while the favicon is vertically centered against one-, two-, or three-line titles.
RSVP has no scroll surface, so its pinned title stays visible through immersion and
its layout never changes. `ReaderHostFactory(includesArticleTitle: false)` still
suppresses the scroll reader's old attributed-string title to avoid a third copy.
Fullscreen, share-extension, and non-carousel readers keep the original inline title.

Original mode applies the same stable top content inset directly to its WKWebView.
A layer restored with `.original` compares the actually mounted child (rather than
mistaking the restored mode value for an already-mounted reader), so a cold launch
loads the saved web archive immediately without requiring a mode round trip.

The scroll reader (`ScrollReaderViewController`) backs Scroll only via `init(audioEnabled:)`: audio → `SpeechController`; else plain. The footer routes play/pause/skip/speed to the speech engine.

## Scroll reader (+ split-web link handling)

- `Luna/Reader/ScrollReaderViewController.swift` — full-screen `UITextView`, serif type, attributed text from `ArticleTextRenderer`. Link taps intercepted via `textView(_:primaryActionFor:defaultAction:)` → opens the split instead of Safari. Bolt button → RSVP.
- `Luna/Reader/ArticleTextRenderer.swift` — blocks → `NSAttributedString` (title, headings, quotes, bullets, `.link` attributes from stored UTF-16 ranges).
- `LunaReaderUI/SplitWebOverlayViewController.swift` is the nested reader card.
  Link activation resolves the link glyph/pill center and runs
  a real custom UIKit presentation driven by `InlineReaderEclipseScene`: a black circle
  expands from that point while a second
  reader-sized black surface fades in below and translates upward. Its corona and
  diamond-ring flare meet at the center of the incoming reader's content edge, below
  the tabs. The flare and rounded-card corona reuse the exact public root-carousel
  visuals and keyframe timing. Only after totality does the already-laid-out
  new page fade in and the covered reader's tab spring upward from behind the front
  card; existing tabs animate to their new positions and widths at the same time.
  Dismissal and nested pops run that choreography in reverse: content and
  the newest tab sink into totality before the eclipse drops and contracts back to the
  source link. Reduce Motion uses a short ordered crossfade.
- The hidden-bar child `UINavigationController` still owns the linked-page stack.
  Every embedded Scroll/RSVP link reports its source point through
  `onLinkActivatedAtPoint`, so every depth uses the same eclipse rather than a stock
  navigation push. `InlineReaderPageViewController` keeps the existing cached article
  probe, themed-web fallback, and reader-mode switching, and now reports extracted or
  WebKit titles for tab updates.
- The inline surface has no Close, Save, or duplicate mode control. Its only local
  chrome is the ancestor-tab strip outside and above the reader card, inset on both
  sides by the card's 22pt corner radius. Each system-background tab (white in light,
  black in dark) has a Liquid Glass top/side rim with deeply rounded top corners and
  square bottom corners hidden behind the front card. Deeper tabs overlap ancestors.
  Tabs hug their favicon/title content while room remains, share width when constrained,
  then become horizontally scrollable at the favicon minimum and initially align to the
  rightmost content. Tabs
  preserve their button instances while metadata changes so in-flight favicon fetches
  are not cancelled. Each contains an asynchronously fetched favicon (with a visible
  globe badge while it loads) plus a truncating title; when squeezed to
  the minimum, the title hides and the favicon remains. Selecting a tab unwinds to that
  reader (the outermost tab dismisses the overlay). `InlineReaderTabMetrics` is the
  pure, unit-tested fit/scroll sizing policy.
- `ReaderChromeControlling` lets the fixed outer reader chrome retarget itself to the
  innermost inline page. The exact same segmented control and audio button stay in place;
  they switch the inline page's Scroll/RSVP/Original mode and read-aloud state, then return
  to the outer reader on dismissal. The same share button targets the innermost URL/title.
  The modal stays inside the root card's resting footprint: its tabs consume the top
  42 points, and its `CarouselCardView` begins below them with its height shortened by
  the same amount. Its presentation frame always comes from the carousel's resting-card
  geometry, never the live outer card bounds that extend to the screen bottom during
  immersion. This leaves the persistent controls unobstructed while the immersed
  outer card remains visible below through a very light blur when it is scrollable.
  Scroll and Original/Web pages use a host-managed horizon-point indicator at the
  inline card's trailing edge; the root card host retakes its indicator from the
  presentation controller's completed-dismissal callback (not the short-lived animator).
  `InlineReaderEclipseScene.sceneFrame` clips both directions to the card content edge,
  never the tabs. Inline scrolling has normal rubber-banding and never dismisses a reader.
- The old split snapshots/peek views are no longer created. The outgoing live reader
  remains underneath a custom presentation controller that deliberately retains it,
  and its scroll position is restored on dismissal.
  When the reader is still embedded in the root card carousel, link activation also
  calls the same carousel immersion path as scrolling down, fading the side cards,
  rims, and scrub strip in step with the opening eclipse. Animation work is limited
  to pre-laid-out views, transforms, opacity, and a tiny drawn flare; favicon and
  extraction network work stays asynchronous. Simulator-only "Split High"/"Split Low"
  buttons still exercise high/low source origins.
  After the reverse eclipse, a root scroll reader already at its top, or a paused root
  RSVP reader, also surfaces the carousel back into card view. That carousel chrome
  restoration now begins with the reverse eclipse (and reverses if UIKit cancels the
  dismissal); the completed-dismissal callback remains responsible for committing the
  stable chrome target and other state-machine cleanup.

## RSVP reader (ReadMaxx-style) — Words + Phrases sub-modes

- `ReaderKit/RSVPEngine.swift` — pure logic, unit-tested. Tokenizes blocks into `RSVPWord`s (the shared word space both sub-modes index). ORP index by length: 1→0, 2–5→1, 6–9→2, 10+→3. `duration(at:wpm:)` (Words timing) = 60/wpm × length factor (≤5: 1.0, 6–9: 1.3, 10+: 1.6) × pause factor (paragraph end 2.5, sentence end 1.8, clause `,;:` 1.3). **Words-mode behavior is unchanged.**
- `ReaderKit/ChunkPlanner.swift` + `ReaderKit/ReadingHeuristics.swift` — pure, unit-tested phrase engine driving the **Phrases** sub-mode (no `WordMap`/NSRange — it builds directly from the `RSVPEngine` word stream). `ChunkPlanner.chunks(words:)` groups words into phrases (≤5 words / ≤30 chars, never ending on a determiner/preposition, breaking before phrase starters and at clause/sentence ends); `duration(for:wpm:)` weights per-word time by `ReadingHeuristics.difficultyFactor` (function words 0.6, long/≥4-syllable 1.35–1.7, numeric ≥1.4) plus a punctuation pause, floored at `minimumDisplay` (0.28s) so phrases stay legible at high WPM. `ReadingHeuristics` holds the function-word sets (binders / phrase-starters), a vowel-group syllable estimate, and the difficulty model.
- `ReaderKit/RSVPViewController.swift` — hosts both sub-modes (`subModeControl`, default from `ReaderSettings.rsvpMode`). **Words**: word positioned so the ORP letter (tinted in the reading accent) sits on a fixed focal column (40% width) between two glass reticule marks (`GlassStyle.reticuleMark()`); context shows only while paused. **Phrases**: the chunk's words shown over two lines (`phraseLabel`, `numberOfLines = 2`, smaller proportional font, shrink-to-fit safety net) behind a glass `phrasePanel` (`GlassStyle.focusPanel()`), with `previousContextLabel`/`nextContextLabel` ALWAYS visible and re-filled on every advance (excluding the words in the reticule); with audio on, `willSpeakRangeOfSpeechString` advances the displayed phrase to follow the spoken word and tints that word. Shared across both: tap = play/pause; scrubber (accent tint, pauses while scrubbing) — scrubbing/skip snap to the containing phrase in Phrases; **±25-word skip buttons**; ±25 wpm buttons (persisted via `ReaderSettings.baseWPM`, 100–900, default 300); "% · wpm" status; light haptic at sentence/paragraph ends; resume via `ReadingListItem.lastWordIndex` saved on pause/close.
  - **Skip = ±25 words, playback-state-preserving** (`skip(by:)`): target = `RSVPEngine.skipTarget(currentIndex:by:wordCount:)` (pure, clamped to `0…lastWord`, unit-tested for both ends / ±25 / short / empty docs). It captures `wasPlaying`, tears down the active engine (WPM timer in silent mode, synthesizer in read-aloud mode) WITHOUT flipping the play/pause glyph, seeks (`currentIndex` + displayed word + scrubber + status), then restores the exact prior state — resumes from the new word (`scheduleNext`/`speakCurrentSentence`) if it was playing, stays paused otherwise. Never toggles play/pause, never restarts from the beginning, never desyncs the displayed word from the engine; the audio session is left untouched so read-aloud resumes seamlessly.

### Link-hold mini RSVP preview

Long-pressing an inline link in Scroll, or the current link pill in RSVP, opens
`LunaReaderUI/LinkRSVPPreview.swift`: a compact glass RSVP reader that exists only for
the lifetime of that finger unless locked. It appears and starts playback immediately
on the press, finger stationary — the interaction's delegate makes every non-pan
recognizer sharing the touch (context-menu presses, a host carousel's long-press,
whether installed before or after it, at any hierarchy level) require the link-only
press's failure, so none of them can recognize mid-hold and cancel the preview; pans
stay independent so a drag that starts on a link still scrolls. One hazard lives
OUTSIDE the failure-requirement graph: a `UIContextMenuInteraction` anywhere on the
touch's view chain whose delegate answers nil config installs a long-press "click
driver" (`_UITouchDurationObservingGestureRecognizer` + `_UIRelationshipGestureRecognizer`
pairs) that never fails while the finger is stationary and gates ACTION DELIVERY for
every other long press — the link press transitions to `.began` but its handler doesn't
run until the finger moves or lifts. `CardCarouselViewController` therefore installs its
per-card context-menu interaction only for cards whose delegate actually provides a menu
(reader cards don't; Downloader media cards do). A small glass capsule
floats above the card with an up chevron and "More actions", signalling the drag-up
menu; it hides while the menu is up and once the card locks. It resolves the linked
article from the saved item, preload cache, or a fresh extraction. Playback begins with the complete page title
(`Resuming: <title>` when its word index is nonzero) held for at least 1.4 seconds, then
continues at the saved position. The focus region is permanently two lines high; only the
title uses both lines, shrinking and finally ellipsizing if necessary, so switching to the
single-line ORP word display never changes popover geometry. Its entrance mirrors a
system long-press context-menu preview: the backdrop eases in while the card and its
action hint fade, scale, and lift toward rest with a tightly damped spring directed away
from the held point.

The hold gesture is a single state machine (`LinkRSVPPreviewGesturePolicy`, unit-tested in
`LinkRSVPPreviewGesturePolicyTests`): horizontal movement beyond a 24pt dead zone scales
playback continuously from half to double the saved WPM without changing
`ReaderSettings.baseWPM`; dragging fully left pauses and reveals the preceding/following
word context. The card prefers an anchor 38pt above the held finger, falling below it only
when the top safe area leaves insufficient room. The initial hold uses the system-style
medium link haptic; both vertical directions produce three very-soft, increasing ticks near
their threshold and one medium confirmation tick on crossing it. 56pt down arms a low-alpha
lock and releasing keeps the preview open until an outside tap; the lock fades while the card
grows a glass chin containing play/pause, ±25 WPM, ±25-word skip, and read-aloud controls.
56pt up pauses playback and fades in the one canonical link menu
(Share Link / Copy Link / Open Link); Open Link uses the Safari compass icon and hands the
URL to the system browser outside Luna. The menu supports drag-to-highlight and
release-to-select; its ORIGIN is owned exclusively by `positionMenu` (anchored to the
press's start point, overlapping the card) — `viewDidLayoutSubviews` sets only its size,
because any layout-derived default origin visibly teleported the menu above the card
whenever a layout pass landed while it was up or still fading out. Moving
back below the upward threshold fades the menu out and resumes. Normal release saves the
current token index and dismisses. Saved links write their regular `lastWordIndex` and clear
the stale scroll offset; unsaved links use a bounded App-Group URL→word map in
`ReaderSettings`, so they also resume across preview sessions. The Scroll reader suppresses
its former duplicated UIKit link menu; its plain-text sentence-selection hold is unchanged.
- `Luna/Settings/ReaderSettings.swift` — base WPM in standard defaults (also adjustable in Settings screen slider).

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
- **End-of-article share** (`Luna/Reader/ArticleShareView.swift`): separator + "Done reading? Share it." + Share button + one-tap "Send to <friend>" suggestion. The Share button → `ReaderShareProviding.presentShareSheet`. Scroll reader appends it below the text (subview positioned via a `contentSize` observer; `contentInset.bottom` reserved so it clears the floating footer); RSVP fades it in above the controls on finish.

## Reader share sheet (the share button) — Feature C

The reader's nav-bar/footer Share button routes through `ReaderShareProviding.presentShareSheet`. In the main app, `AppReaderShareProvider` presents `Luna/Social/ReaderShareSheet.swift` — a medium-detent `UISheetPresentationController` with up to five options: **Send to {suggested friend}** (one tap, shown only when a streak/semantic suggestion exists), **Send to a Friend…** (`SendToFriendSheet.present` — recent-recipient bottom sheet, or the full picker when there are no past sends), **Share Link…** (`SendToFriendSheet.shareLink`), **Copy Link** (`SendToFriendSheet.copyLink`), **Share eBook…** (`ArticleExportService.presentShareSheet`, see article-export.md). Share Link hands the system share sheet a Reader/Downloader App Clip invocation URL from `LunaReaderAppClipURL` / `LunaDownloaderAppClipURL` when configured; Copy Link always copies the plain source URL. Rows are a pure `ReaderShareSheet.rows(…)` list (testable visibility/actions); tapping dismisses the sheet then runs the action.

## Reader App Clip

`LunaReaderClip` is an App Clip target embedded by the Reader app. It accepts the same
invocation shape as the Downloader clip (`?url=`, `?source=`, `?sourceURL=`, `?u=`, or a
fragment) via `LunaAppClipInvocationURL.sourceURL(from:)`, runs the shared
`IngestPipeline`, and presents the normal `ReaderViewController` with `forceMode: .scroll`,
`persistsModePreference: false`, `marksOpenedOnLoad: false`, and `shareProvider: nil`.
That keeps the clip read-only: no saved-list writes, no Save affordance, and no reader share
button (iOS does not provide an API for an app/app clip to launch its own share extension as
a share target). The live web URL is a normal shareable `ReadingListItem`, so the standard
Original-mode capability path (`canHaveOriginalArchive` → live-page fallback) still appends
Original alongside Scroll and RSVP.

## Share-sheet reader experience

Fixed behavior: the **share extension** (`com.apple.share-services`) always saves + dismisses, for every URL. The **"Read in Luna" action extension** (`com.apple.ui-services`) routes via `ShareViewController.presentSavedOrReader`:
- **Article URLs** → `ShareKit/ShareReaderViewController` fetches + extracts (`ArticleFetcher` + `ArticleExtractor`) and presents the **real** `ReaderViewController` with a lightweight **`ExtensionReaderShareProvider`** (Feature D) — so the end-of-article share affordance works: it offers a friend picker (friends read from the App Group via `ExtensionFriendsReader`; the send is QUEUED to `pendingFriendShares.json` via `PendingFriendShareWriter` for the main app to deliver — no CloudKit in the extension) plus a link share. No suggestion engine in the extension, so no one-tap suggested send. The action ext keeps its OWN last-used mode in `ShareKit/ActionReaderMode` (private `UserDefaults.standard`); `ReaderViewController(persistsModePreference:false, onModeChange:)` writes there, not the shared `ReaderSettings`. If fetch/extract fails, `presentFailure()` shows a red error state (warning glyph + message) with Done available.

All three reader modes, audio (foreground only), and the inline split-web link viewer work; a Done button exits the extension. Resume starts from the first fully-visible word (`ScrollReaderViewController.firstFullyVisibleWordIndex`).

**Deep links**: `lunareader://read?url=…` (`LunaDeepLink`) opens the app and loads that article in the reader (`SceneDelegate.openReader`). Schemes are per-app now — `lunareader://` (Reader), `lunadownloader://` (Downloader), `lunapricetracker://` (Price Tracker), via the per-target `LUNA_URL_SCHEME` build setting — and parsing accepts any of the three. The in-app "Share Link…" shares this link. (A custom scheme opens the app only when installed; App-Store fallback would need a Universal Link.)

## Inline images

Extractor emits `.image` blocks (`imageURLString`) for article `<img>`s — token-exact junk filter (ad/tracking/logo/etc; substring matching would reject WordPress `/uploads/` URLs) and skips declared-tiny (<140 px), svg/gif. Ingestor downloads up to 8 (≤5 MB each) into the Articles dir (`imageFileName`); failed downloads drop the block. `ArticleTextRenderer` inlines them as `NSTextAttachment`s via ImageIO downsampling (never decodes full-size). RSVP ignores image blocks (no tokens).

## Article extraction (`ReaderKit/ArticleExtraction.swift` + `ArticleExtractor.swift`)

**Stage-2 component (`ArticleExtraction`).** The ONE place HTML becomes content AND is judged readable. Wraps the pure `ArticleExtractor` parser and exposes: `extract(html:baseURL:)`, `extractFromJSONLD(html:baseURL:)`, the shared `fetchAndExtract(baseURL:fetch:) -> ExtractedArticle?` helper (one fetch-then-extract for the whole pipeline — the byte-identical `ArticleResolver.extractedContent` / `BypassRunner.extracted` duplicates were deleted), and the SINGLE predicate `static isReadableArticle(_:html:)`. That predicate (`bodyTextLength >= ArticleContent.readableBodyThreshold && !PaywallDetector.looksPaywalled(content:html:)`) consolidated the three former duplicate readable/locked checks — `ArticleResolver.isReadable`, `BypassGate` step 3, and the implicit `!looksPaywalled` inside `ArticleContent.hasReadableBody`. It is HTML-aware (folds in the schema.org lock), so the lock can't be skipped via a text-only path. `ExtractedArticle { content, sourceHTML }` replaces the old `(ArticleContent, String)` tuple. `ArticleContent.hasReadableBody` is now a thin text-only (`html: nil`) call into the predicate. Tests: `ArticleExtractionTests` (per-site readable + paywalled-stub table for nytimes/washingtonpost/wsj/smh.com.au; the HTML-lock false-negative guard; long-article-quoting-a-gate-phrase policy locked).

Layered readability: **refined** (aggressive junk-by-class stripping — footers, share/social bars, related rails, **comments**, **subscribe/paywall promos**, newsletter prompts) → **basic** (structural tags only) → JSON-LD `articleBody` → raw body text. `extract()` **trusts a substantial refined result** (≥600 chars) even when `basic` is much larger; the `refined*3 ≥ basic` guard only arbitrates a *medium* refined (350–600). This is the fix for archived WSJ/FT snapshots, where a long reader-comments thread + subscription gate hold more `<p>` text than the article — the old guard fell back to the unstripped `basic` pass and surfaced gate + comments instead of the body. `bestContainer` also **prefers an explicit article-body container** (`[itemprop=articleBody]`, `[class*=article-body|articleBody|article-content]`, …) with ≥400 chars before paragraph-scoring, so both layers target the prose.

**Paragraph-like `<div>`/`<section>`**: scoring and block extraction treat a `<div>`/`<section>` with **no block-level child element** (pure inline/text) as a paragraph — `isParagraphLikeContainer` / `paragraphLikeElements`. archive.today rewrites the captured page so **every body paragraph is a styled `<div>` with no `<p>` at all**; without this the whole body is invisible (extraction collapsed to the title + a stray summary box, ~1k chars). Div/section paragraph blocks must clear the same **>20-char** bar scoring uses, so short UI chrome (timecodes, "Up Next", labels) isn't emitted; explicit `<p>`/heading/list/quote tags keep any-length behavior.

**Player + hidden chrome**: refined also strips `[class*=video|player]`, `[id*=video|player]`, `[aria-live]`, `[role=slider|menu|menubar]`, and **visually-hidden / sr-only** elements (`removeVisuallyHiddenElements` — `clip:rect(1px…)`, `clip-path:inset(50%)`, 1px boxes) so an embedded video player's chrome and screen-reader labels don't leak once div-text is captured.

Regression tests: `ArticleExtractorTests.testArchivedArticleBeatsSubscriptionGateAndComments`, `…testDivBasedArticleBodyExtractedWithoutPlayerChrome`.

## Hard-paywall resolution & archive reader

**Paywall detection** is one shared, content-based `PaywallDetector` (ReaderKit) — NOT a host allowlist (so a reader logged in via their browser gets the full article and isn't flagged): **gate markers** ("login or signup to continue", "subscribe to read", …) flag a wall at any body length; **weak markers** (subscribe now, support local journalism, …) flag only a short body; and `htmlDeclaresLocked` reads schema.org `isAccessibleForFree:false` / an `article:content_tier` meta. `ArticleContent.looksPaywalled` and `ArticleResolver` use it; a JS mirror lives in the Safari extension's `content.js` (keep the marker lists in sync). Tests: `PaywallDetectorTests`.


**Shared pipeline (`ReaderKit/IngestPipeline.swift`).** The SINGLE dep-free entry `IngestPipeline.process(_ input: IngestInput, timeout:…, …) async -> Outcome` runs the WHOLE pipeline ONCE — (1) `URLUnwrapper.unwrap` once; (2) `Classifier.classify` (deterministic table FIRST — platform/video/document decided before any fetch, so a video can never reach extraction); (3) per-kind processing: product detection (→ `Outcome.product`, never paywall-bypassed; `IngestInput.forceArticle` forces the article path for "Read instead") → gated article resolution via `ArticleResolver.resolve` → `.article` / `.needsArchive` / `.failed`. The whole call is wrapped in ONE overall timeout (`processTimeout = 28s`) so it can never hang. **All six surfaces call this exact entry** and differ ONLY in their `OutcomePresenter` (the protocol's exhaustive `Outcome` switch, no `default`): `ReadingListIngestor.ingest` → `IngestorOutcomePresenter` (main app — list state + images/cover), `ShareViewController` (both extensions) → `ShareOutcomePresenter` (inline reader / saved-non-textual / archive reader / saved checkmark / error), `ShareReaderViewController.ingestAndPresent` (action-ext reader, takes the pre-computed `Outcome`), plus app intents + incoming friend share via the ingestor. `render` defaults nil in the extensions (no WebView — the "spins forever" fix); the main app injects `WebViewPriceRenderer`. Replaces the deleted `ArticleIngestDecider`. Tests: `IngestPipelineTests` (parity: same `IngestInput` across all `CaptureSource`s → same `Outcome`; platform/video recognized before extraction; overall-timeout never hangs) + `OutcomePresenterTests` (outcome→UI mapping; `.failed` never "Saved").

**Deterministic direct fetch (Stage 2).** `ArticleFetcher.fetchHTML(from:)` now uses ONE UA (Safari) with no fallback chain — the bytes a normal reader sees, so the paywall judgment is reproducible run-to-run. The Googlebot crawler trick is NOT the default read; it is the explicit `.userAgent(.googlebotDesktop)` bypass strategy (`CrawlerAgent.googlebotDesktop`, the de-duplicated Googlebot UA). Tests: `ArticleFetcherTests`.

**Data-driven bypass pipeline.** `ArticleResolver.resolve` is now: direct fetch (reusing `prefetchedHTML` when supplied) via the shared `ArticleExtraction.fetchAndExtract` → if `isReadableArticle` return → else build ONE `BypassPlan.make(for:directHTML:)` and walk its `silent` leg (bounded by `BypassPlan.silentChainDeadlineSeconds = 20`) until one yields a readable, non-locked `ExtractedArticle` → else `resolution(...)`. The loop ADVANCES on any nil OR non-readable/locked result and STOPS at the first readable one (tested in `ArticleResolverTests`: advance-past-failing, reject-unreadable-and-advance, fall-all-the-way-to-paywalled). The legacy trailing `fetchArchivedHTML` last-silent attempt was DELETED (`.waybackRaw` already covers Wayback in every rule; `archive.ph/newest` belongs to the WKWebView terminal flow) — removing the duplicate Wayback hit + near-always-failing archive.ph GET is the NYT/WSJ "no silent strategy worked" speed fix; `fetchArchivedHTML`/`fetchArchiveTodayHTML` were removed from `HTMLFetching` and all conformers. The `.readable/.paywalled/.unreadable` → `Outcome` mapping (in `IngestPipeline`) is unchanged. Pieces (all in `ReaderKit/`):
- `BypassPlan` (`BypassPlan.swift`) — ONE typed `{ silent: [SilentStrategy], webPreStages: [WebStrategy], allowsArchiveToday: Bool }` built by a single factory `make(for:directHTML:)` that splits `BypassStrategySelector`'s ordered list into the typed legs. Both the resolver (silent) and the archive reader (web) consume it, so they can no longer derive divergent orderings (the former double-compute). `SilentStrategy`/`WebStrategy` make the silent/web split unrepresentable (no more "skip the non-silent cases" filter). Trailing-dot is the first silent strategy and `benefitsFromJSRetry == false`, so the factory NEVER repeats it as a ~9s WKWebView pre-stage (the NYT slowness). Tests: `BypassPlanTests`.
- `BypassURLs` (`BypassPlan.swift`) — the ONE strategy→URL mapper (`requestURL(for:article:)` silent, `loadURL(for:article:)` web), replacing the duplicated `switch strategy → URL` in `BypassRunner.run` + `webPreStageURLs`.
- `BypassStrategy` (`BypassStrategy.swift`) — the technique enum. Cases: `.jsonLDBody`, `.userAgent(CrawlerAgent)`, `.referer(RefererOrigin)`, `.trailingDotHost`, `.freshSession`, `.amp`, `.waybackRaw`, `.jinaReader`, `.ladderProxy(LadderProxy)`, `.thirdPartyWeb(ThirdPartyWebService)`, `.archiveToday`. `runsSilently` is false only for `.thirdPartyWeb` + `.archiveToday` (WKWebView-only). `CrawlerAgent` (googlebotDesktop/Mobile + Googlebot XFF `66.249.66.1`; bingbot, no XFF), `RefererOrigin` (google/facebook/twitter), `LadderProxy.oneFt` (silent server-render proxy), `ThirdPartyWebService` (.smry/.removePaywalls/.removePaywall) carry the verified service URL builders.
- `BypassRuleTable` (`BypassRuleTable.swift`) — static per-host literal (`rule(for:)`, apex+subdomain+trailing-dot match). Seeds ~21 hosts (WSJ/FT/NYT/Economist/Bloomberg/…); every rule ends in `.archiveToday`.
- `BypassStrategySelector.strategies(for:directHTML:)` (`BypassStrategySelector.swift`) — PURE. `[]` when `BypassGate.decision(for:html:extracted:nil)` blocks a bypass (product/platform/readable/not-paywalled). A supported site rule always uses its direct-unlock pre-stage before archive.today; other eligible pages use archive.today (NYT retains its trailing-dot pre-stage). There is no user gate for on-device paywall unlocking.
  - **OFF (default)** → `[.archiveToday]` (+ `.trailingDotHost` first for NYT-family). A detected paywall goes STRAIGHT to the archive reader — the long-standing behavior, no silent fetches, no pre-archive hang.
  - **ON** → a **first-party silent chain** (`firstPartySilent`) then the WKWebView **`.directUnlock`** stage, then archive.today: `[.jsonLDBody, .userAgent(.googlebotDesktop), .userAgent(.googlebotMobile), .freshSession, .amp, .waybackRaw, .directUnlock]` (+ `.trailingDotHost` for NYT) + `.archiveToday`. ON also lets a **rule-listed paywall host** (`PaywallUnlockRules.isKnownPaywallHost`) enter the unlock flow even when the gate found no generic evidence — but ONLY overriding the `.notPaywalled` "no evidence" block, never a readable article / product page / platform link. The silent reads run over URLSession **from the user's own device IP**, which is the point for hard paywalls (esp. **WSJ**): WSJ/Reuters/etc. block the datacenter IPs archive.today and Wayback crawl from (verified: WSJ + Reuters 401 a datacenter IP regardless of UA; and archive.is returns `-32602 cannot archive` on new WSJ articles), so the archiver only gets a teaser/CAPTCHA loop, whereas a Googlebot-UA + cookieless read from the reader's residential/cellular IP *may* get the full article (WSJ serves full text to Googlebot for SEO; UA-based — same as the reference paywall rules' `wsj.com → useragent: "googlebot"` + cleared cookies). **Default OFF because the silent chain adds up to ~20s of pre-archive latency and, in practice, WSJ also appears to reject Googlebot from arbitrary IPs — so the chain often doesn't help and the wait was a regression.** The Googlebot read is cookieless (`ArticleFetcher.fetchHTML(from:userAgent:xForwardedFor:)` uses an ephemeral session). Third-party reader/proxy services (`.jinaReader`/`.ladderProxy`/third-party pages) are deliberately NOT used — only first-party reads + the public archives.
- `BypassRunner` (`BypassRunner.swift`, protocol `BypassRunning` + mock) — maps each SILENT strategy to a `HTMLFetching` call (URLs via `BypassURLs`) + the shared `ArticleExtraction.fetchAndExtract`, returning `ExtractedArticle?`; WKWebView-only strategies return nil. `.jsonLDBody` is zero-network (`extractFromJSONLD` forces the JSON-LD `articleBody` layer even on a paywalled-looking DOM).
- `HTMLFetching` protocol on `ArticleFetcher` (+ `MockArticleFetcher` in tests) so the resolver/runner are network-free in unit tests. Silent fetches: crawler UA/XFF, spoofed referer, ephemeral no-cookie session, `fetchWaybackRawHTML` (CDX newest-200 → raw `…/web/<ts>id_/<url>` replay; pure parser `newestSnapshotTimestamp(fromCDXJSON:)`), `fetchJinaReader`. (`fetchArchivedHTML` was removed — see above.)

Third-party service request formats (owner-required fallbacks): `1ft.io/<raw url>` (silent), `smry.ai/<raw url>` + `removepaywalls.com/<raw url>` (WKWebView, path prefix) + `www.removepaywall.com/search?url=<encoded>` (WKWebView, query param), Wayback raw (silent), archive.today (WKWebView terminal). All fail gracefully — a dead one falls through via the readability gate. Tests: `BypassStrategySelectorTests`, `BypassRuleTableTests`, `BypassRunnerTests`, `BypassServiceURLTests`, `WaybackCDXTests`, `JSONLDExtractorTests`, `TrailingDotBypassTests`, `ArchiveWebPreStageTests` (fixtures under `LunaTests/Fixtures/`).

`resolution(...)` counts an `ExtractedArticle` readable via the shared `ArticleExtraction.isReadableArticle` predicate (the only place that decision lives). Outcome → ingestor state:
- `.readable` → `.ready`.
- `.paywalled(title)` → `.needsCaptcha`.
- `.unreadable` → `.failed` **only for ordinary sites**. For a **hard-paywall host** (`ArticleFetcher.isHardPaywallHost` — WSJ/FT/NYT/Economist/Bloomberg/…) **or an archive.today URL** (`isArchiveTodayURL`), it parks as `.needsCaptcha` with a humanized placeholder title (`articleTitleGuess`, slug-derived, archive URLs unwrapped to the original via `originalURL(fromArchiveURL:)`). So a blocked WSJ/FT save offers the archive path instead of dropping into failed imports.

Opening a `.needsCaptcha` item (`ReadingListViewController.presentArchiveReader`) presents the WKWebView **`ArchiveWebReaderViewController`** (NOT SFSafariViewController — the host app can't read SFSafari's DOM, so it could never extract). It loads the exact snapshot when the saved URL is already archive.today, else `archive.is/newest/<canonical>`; persistent cookie store + device-matched Safari UA so a solved Cloudflare `cf_clearance` sticks. On `didFinish` with innerText > 1500 (and not the challenge page) it reads its own `outerHTML`, extracts, `saveContent`, and fires `onExtracted` → the host dismisses and reopens the now-`.ready` item in the native reader. An **"Open in Safari"** button (`onOpenInBrowser` → `SFSafariViewController`) is the escape hatch when the embedded view can't clear the gate. Tests: `ArticleFetcherTests` (host detection, archive-URL unwrap, title guess).

**Ordered WKWebView pre-stage list.** Before any archive.today navigation, the reader walks an ordered list of WKWebView pre-stage URLs — `ArchiveWebReaderViewController.webPreStageURLs(for:)` (pure, static, tested by `ArchiveWebPreStageTests`): the `BypassPlan.make(for:directHTML:nil).webPreStages` leg mapped to loadable URLs via `BypassURLs.loadURL`. The plan only includes a `.trailingDotHost` pre-stage when it did NOT run silently (it doesn't `benefitsFromJSRetry` — a pure origin trick returns the same wall in a browser), so a host like NYT whose rule leads with a silent trailing-dot goes silent-trailing-dot → (fail) → third-party pages → archive.today, skipping the ~9s redundant trailing-dot pre-stage (the speed fix). `.thirdPartyWeb` → smry.ai/removepaywall(s).com page URLs. archive.today (the terminal flow) is excluded; an archive.today URL yields no pre-stages. `checkStage` routes to `checkDirectBypassStage` while `isAttemptingDirectBypass`: poll the page's text length and `extractAndSave` (baseURL stays the canonical article URL); a readable extraction from ANY pre-stage finishes via the normal `onExtracted` path (no archive.today at all). If the current pre-stage doesn't yield a readable article within `bypassPollLimit` (≈9s), `advanceToNextPreStage` loads the next one; when the list is exhausted, `fallBackToArchiveFromBypass` switches to the standard archive.today flow (`loadArchive` + `resolveSnapshotInParallel`). The trailing-dot transform is the former NYT pre-stage, now emitted by the selector for any host with a `.trailingDotHost` strategy (NYT/WaPo/LAT/… per the rule table + the generic metered branch). Unit-tested (`TrailingDotBypassTests`, `ArchiveWebPreStageTests`).

**Snapshot resolution (avoid the `/newest/` loop).** Hitting `archive.is/newest/<url>` cold triggers archive.today's self-reloading CAPTCHA loop. So the reader loads the **`archive.is/` homepage** and reaches the snapshot the way the site itself does: a **`pollTimer`** (1.3s; a timer, not `didFinish`, because clearing the CAPTCHA is often an in-page transition that fires no navigation callback) runs `checkStage()` → a JS probe returning `challenge` / `homepage:<len>` / `page:<len>`, mapped to an action by the pure, unit-tested **`decideStage(...)`** (see `ArchiveStageDecisionTests`). **Before** submitting (`!didLeaveHomepage`), a `homepage` stage (the `input[name=url]` search box is present = gate cleared) means **types the article URL into `input[name=url]` and submits the form** (`submitURLOnHomepage` — POSTs to `/submit/`, which 302-redirects to the existing snapshot for an already-archived page; this is exactly the working manual flow), or loads the TimeMap-resolved snapshot if one resolved first. **After** submitting, a lingering `homepage:<len>` is NOT re-treated as the homepage: archive.today's chrome carries that `input[name=url]` box on **every** page (homepage, the `/wip/` progress shell, AND the rendered snapshot), so it falls through to the same length gate as `page` — on `len>1500` it calls `extractAndSave`, whose `hasReadableBody` (≥600 block chars, not paywalled) is the final arbiter. This is what catches the **`/wip/` → article transition** (archive.today renders the saved article in place at the `/wip/<id>` URL, firing no navigation callback): the progress shell's request-log has no article blocks and fails the readability gate (keep polling), the rendered article passes and extracts → `onExtracted` closes the web view into the native reader. (Without this, the ever-present url-box pinned the spinner forever once `/wip/` rendered the article.) In parallel, `ArticleFetcher.resolveNewestArchiveSnapshot` (Memento TimeMap `/timemap/<url>` → `newestMemento(fromTimeMap:)`, a clean read endpoint off the CAPTCHA'd write path) is a best-effort fast path. See `archive-today-research.md` (DNS/EDNS + IP reputation are the real loop drivers; archive.today uses reCAPTCHA, which WKWebView *can* solve, not Turnstile).

**Hidden flow + escape hatches.** The raw archive.today navigation is covered by an opaque themed overlay (spinner, "Unlocking article…"); `checkStage` reveals the web view ONLY when `stage == challenge` (the user solves the CAPTCHA), re-covering for every automated step, then dismisses into the native reader. **Terminal failures display IN the overlay, not a popup** (`showTerminalMessage`): the spinner stops, the cover goes fully opaque, and it shows a message plus an **"Open in Safari"** button (hidden in extensions). Cases: (1) **rate-limit** — a 429 loop (≥3) or the **stall guard** (overlay covering the page ~30s without progress) shows the rate-limit guidance; (2) **un-archivable** — archive.today's capture-session error **"Error -32602: Invalid InterceptionId"** (probe stage `error`, matched on the code or the phrase) is terminal — no retry/solve helps — and shows "This site can't be archived right now."; (3) **JS/ad-blocker gate** — archive.today's "Please enable JS and disable any ad blocker" interstitial (probe stage `blocked`, matched on a SHORT body so real articles can't trip it) doesn't clear in a WKWebView (JS is on; we install no content blocker), so after `blockedPollLimit` (3 ticks ≈ 4s, tolerating a transient flash) it shows the same un-archivable message + Safari escape. `showTerminalMessage` invalidates the `pollTimer` and latches `didShowTerminalMessage` so no in-flight probe re-covers/re-drives the page; the timer is also invalidated in `viewDidDisappear`. The submit fills `input[name=url]` and submits immediately (no `submitid` wait — that was the build-79 "spinner forever" regression).

The archive cover starts with a 99% opaque background. Tapping it five times lowers
that background to 10% for the current session and disables its touch handling, so
scroll gestures pass through to the archive web view.

**Safari imitation (best-effort).** A WKWebView can't BE the Safari process like SFSafariViewController, but `ArchiveWebReaderViewController` injects an `atDocumentStart` user script (all frames) defining `navigator.standalone = false` — present in real Safari, `undefined` in a bare WKWebView, and the single most reliable webview tell Cloudflare cross-references against our Safari UA. No `WKScriptMessageHandler` is registered, so `window.webkit.messageHandlers` stays absent too. (Background: SFSafari/Safari TLS+HTTP2 fingerprints match a WKWebView's on iOS — same OS stack — so the difference is the JS/runtime layer, which we can only partly mask.)

**Every paywalled save routes here.** Because all six surfaces share `IngestPipeline`, a genuine paywall classifies as `Outcome.needsArchive(title)` identically everywhere: the main app marks `.needsCaptcha`; the share extension (`ShareOutcomePresenter`) marks `.needsCaptcha` + presents the archive reader inline (`presentArchiveReaderForCaptcha`); the action-extension reader (`ShareReaderViewController`) presents the archive reader and sets `onExtracted` to swap the web view for the native reader once the CAPTCHA is solved. So a WSJ/FT page saved by any method (action ext, share ext, URL paste, friend share) opens the archive CAPTCHA reader on first open and lands in the native reader after solving — and a product page shared via ANY method is saved as a price tracker, never paywall-treated.

A **second, real-Safari path** for paywalled articles (the LunaSafari "Read in Luna" button) is documented in `safari-extension.md`.

## Tests

`LunaTests/RSVPEngineTests.swift` (ORP, Words timing, flags, skip math). `LunaTests/ChunkPlannerTests.swift` (phrase tiling/budget, sentence/phrase-starter breaks, never-ends-on-a-binder, difficulty-weighted timing + floor). `LunaTests/ReadingHeuristicsTests.swift` (function-word classification, syllables, difficulty ordering). `LunaTests/ReaderScreenTests.swift` (scroll / RSVP-words / RSVP-phrases snapshots, 2-segment mode switcher). `LunaTests/ArticleExtractorTests.swift` (layering, junk stripping, archived-page gate/comment rejection).

## Reader appearance (Settings)

`ReaderSettings`: fontScale (S/M/L/XL segmented), useSerifFont, showReadingTime, showReadingProgress — renderer reads font settings at render time; readers persist `readingProgress` (max of scroll depth / RSVP fraction).

## Read-aloud (Luna/Reader/SpeechController.swift)

AVSpeechSynthesizer, block-per-utterance. Scroll reader: floating glass speaker button → footer controls (paragraph skip ±, play/pause, rate cycle 0.8/1/1.2/1.5×); current word highlighted and auto-centered (follow disabled when the user drags, re-enabled on control taps); resume position (`lastSpokenWordIndex`) persisted and highlighted on open until first user scroll. Background playback: `UIBackgroundModes audio`, AVAudioSession `.playback/.spokenAudio`, MPRemoteCommandCenter + NowPlaying. RSVP: speaker toggle speaks whole SENTENCES (natural prosody, normal pace) and flashes each word via `willSpeakRangeOfSpeechString` offsets; WPM ignored. No newer synthesis API exists in the iOS 26/27 SDKs (AVSpeechSynthesizer remains the system API). Word indices shared via `Luna/Reader/WordMap.swift` (built from `RenderedArticle.blockTextRanges`; same tokenization as RSVPEngine).

### TTS engines (`ReaderKit/SpeechEngine.swift` + Settings → Voice)

Voice is abstracted behind `SpeechEngine` (protocol) with `VoiceEngineKind { basic, appleEnhanced }`. There are NO downloadable/neural voices — Luna only uses OS-resident Apple voices (the former Piper/Kokoro Hugging-Face download stack and `VoiceModelRegistry`/`VoiceModelDownloadManager`/`NeuralSpeechEngines` were removed). Both engines drive the SAME `AVSpeechSynthesizer` by CONFIGURING the utterance (voice + rate) via `configure(_:rate:)`, so `willSpeakRangeOfSpeechString` keeps firing and word highlighting works identically. `SpeechController` and RSVP resolve the engine per play session via `SpeechEngineFactory.resolveSelected()`, which is simply "the enhanced Apple voice if one is installed, otherwise basic" — identical in the app and its extensions. Engines:
- **basic** (`BasicSpeechEngine`): system default voice. Always available. The fallback when no enhanced voice is installed.
- **appleEnhanced** (`AppleEnhancedEngine`): best installed enhanced/premium voice for the locale (premium > enhanced). "Availability" = such a voice is installed; apps CANNOT download Apple voices — the user installs them in iOS Settings → Accessibility → Spoken Content → Voices.

`VoiceModelStore` (App Group `group.com.hsanabria.luna`) holds only `hasSeenVoicePrompt` and the convenience `isAppleEnhancedInstalled` check (no engine selection, no on-disk models). **Voice settings** (`Luna/Settings/VoiceSettingsScreen.swift`) is purely informational: it shows whether an enhanced voice is installed and an "Install Enhanced Voices" row that deep-links to iOS Settings via the shared `ReaderKit/VoiceInstallLink.open()` (tries `App-Prefs:root=ACCESSIBILITY` → `App-Prefs:` → `openSettingsURLString`). **First-run prompt**: the first time read-aloud starts in the app, `VoiceFirstRunPrompt.showIfNeeded` shows a one-time non-blocking "Better Voices Available" alert (playback proceeds with the standard voice) gated by `hasSeenVoicePrompt`; the "Open Settings" hook (`VoiceFirstRunPrompt.openVoiceSettings`) is wired in `AppDelegate` and left nil in extensions (so the prompt is main-app only).

## Inline reader content

The card is a single scrollable+navigable `WKWebView` (WebJunkBlocker strips junk/overlays); links inside it navigate the web view in place rather than recursing into more overlays. (Earlier builds extracted an article-like page into a nested viewport-floating text view; the current split model uses the web view directly so it can scroll and navigate independently — far simpler than the old single-outer-scroll viewport hack.) `ReaderKit/ReaderDepth.swift` still tints the card background to the reader's depth-0 color (dark-mode aware).

## Position memory

`lastScrollOffset` restored on open. Read-aloud persists `lastSpokenWordIndex` on close; first-ever audio playback and first-ever RSVP entry start from the first fully-visible word when there's no saved position.

## TextKit note

Reader AND all overlay slices force TextKit 1 at creation (`_ = textView.layoutManager` before text is set): a mid-session TK2→TK1 flip re-breaks lines and visibly shifts text. Slices re-assert driven offsets post-install and on scroll (UITextView clamps programmatic offsets against a stale contentSize on its first layout pass).

## Progressive (two-phase) scroll-reader load

The scroll reader's first-open cost was laying out an ENORMOUS attributed string in the `UITextView` (TextKit glyph generation is O(text length)) — a long article stalled behind the entry animation. `ScrollReaderViewController` now loads in two phases:

- **Phase 1 (instant)**: `init` renders only a leading PREFIX via `ArticleTextRenderer.render(_:characterBudget:)` (budget `ScrollReaderViewController.prefixCharacterBudget` = 700 chars — one+ screen of serif body text; the budget-crossing block is included whole, and `isComplete` reports whether truncation happened). Laying out a few hundred characters is near-instant, so the reader paints immediately.
- **Phase 2 (after entry animation)**: `prepareFullContent()` builds the FULL attributed string off the main actor, then on main swaps it in inside `UIView.performWithoutAnimation`, restoring the captured `contentOffset`. Because the prefix is a STRICT prefix, the leading layout is identical, so the swap is seamless (a `WordMap`-anchored fallback re-positions in the rare case the user was at the bottom of the short prefix). `WordMap` is rebuilt on the full text; the share footer, inline-image fetch, and resume highlight are all deferred until then (they need the full word map). `checkFinishedReading`/share-footer visibility are gated on `didLoadFullContent` so a short prefix isn't mistaken for the whole article.

**Entry-animation hooks** (each calls `prepareFullContent()`, which is idempotent): the standard `ReaderViewController` push (via `ScrollReaderViewController.viewDidAppear`'s transition coordinator — the reader self-triggers regardless of host as a backstop); the split inline reader (`SplitWebOverlayViewController.animateOpen` completion → `InlineReaderPageViewController.entryAnimationDidFinish()`); and the RabbitHole stacked reader (`RabbitHoleReaderViewController` root via `viewDidAppear`, dives via the `runTransition` completion → `RabbitHoleLayerViewController.entryAnimationDidFinish()`). **Phase 2 is SKIPPED** when the prefix already covers a short article, and the FULL render is done up front (no prefix) for read-aloud (audio reads the whole article from the top) and for opens that restore a saved/carried position beyond the prefix (`openPositionLikelyBeyondPrefix`). Tests: `ArticleTextRendererProgressiveTests`.

The Reader carousel adds a stricter host gate around the same mechanism. Side cards and mini-carousel previews mount the real `RabbitHoleReaderViewController`, but `defersFullContentUntilPrimary` keeps ordinary appearance callbacks at Phase 1. When the exact preview controller is promoted into the centered slot, `activatePrimaryContent()` permanently opens the gate for its current and future inline layers and starts Phase 2. Thus the visible preview window is identical to the selected card without paying whole-document text-layout and image-loading costs while scrubbing. Deep saved-position restores remain the exception because Phase 1 must contain the requested viewport.
