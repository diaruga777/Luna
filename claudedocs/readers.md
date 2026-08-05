# Readers

> **Location: `ReaderKit/`** — the entire reader stack lives in a `ReaderKit/`
> synchronized folder that is a member of the `Luna` (main app), `LunaShare`
> (share extension), and `LunaAction` targets, so the share-sheet
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

TWO reading modes for extracted articles, with read-aloud, nested inline readers, and position memory. Hosted by `ReaderKit/ReaderViewController.swift` — a container with a segmented switcher (icons via `ReaderKit/ReaderModeIcons`: `doc.richtext` for the extracted scroll reader / `forward.fill` for RSVP speed reading / a latitude-longitude `globe` for Original) plus a **separate audio toggle** that turns read-aloud on/off for whichever mode is showing. At the Reader card root, the switcher occupies the bottom-center only while card chrome is dismissed, replacing the mini carousel with a short translation + fade; standalone and extension hosts retain their own inline/nav placement. The retired standalone **chunk-highlight ("highlight") mode now lives as the RSVP reader's "Phrases" sub-mode** (see below); a persisted `.highlight` reader mode resolves to RSVP opened in Phrases (`ReaderViewController.opensRSVPInPhrases`, one-shot; `ReaderSettings.lastReaderMode` also maps the legacy value). A third **Original** segment (a locally saved `.webarchive` snapshot or an imported source document) is appended **only when the save actually has one** — `availableModes = baseModes + (ReadingListStore.hasOriginalSource(for:) ? [.original] : [])`. Saves with no real web page (mail/email imports — no web archive AND no source file) therefore never show Original (test: `ReadingListStoreTests.testEmailSaveHasNoOriginalSource`). It persists `lastReaderMode` per article AND globally (`ReaderSettings.lastReaderMode`) — a new article with no per-article preference opens in the global last-used mode. Changing mode/audio replaces the active child directly. RabbitHole layers create and attach only the selected reader child; switching modes removes that child and installs the requested one without keeping hidden reader views in the hierarchy. Scroll readers begin their full-content load as soon as they become visible. Tracks read state (marks `.opened` on open; children call back `onFinishedReading` → `.read`). Reaching the end never dismisses the reader: it visibly draws a trait-aware check into a persistent interactive Liquid Glass “Read” pill below scroll content or in RSVP’s link-pill lane. On tap — and automatically after a beat the first time per app install — the pill expands to “Sent to archive,” then collapses back without disappearing. Completion persists `pendingArchiveAt`; the card remains active for the foreground session, then the Reader app promotes that timestamp to `archivedAt` on background, or during the next cold launch after a force-quit. Scrolling/paging back does not retract a completion. A **floating glass share button** (bottom-right) lifts to clear that mode's footer (`floatingShareBottomInset(for:audioOn:)` — scroll mode only reserves room when read-aloud is on; RSVP is not in that table at all, it hangs off the speed reader's own controls — see "the speed reader's vertical layout" below), and fades out while the end-of-article share footer is scrolled into view (`ScrollReaderViewController.onShareFooterVisibilityChanged`), fading back in otherwise.

**Position carry-over across mode switches** (`ReaderPositionTracking` protocol, `ReaderProviders.swift`): before tearing the outgoing child down, the host reads its `currentReadingWordIndex` and passes it as `resumeWordIndex` to the next child. Scroll plain-mode's reported index is **gated so opening/closing alone never moves the carried position** — the bug was recomputing `firstFullyVisibleWordIndex` on every switch, which drifted the index even when the user did nothing. The decision is a PURE, unit-tested function (`ReaderResumePositionResolver.reportedWordIndex(resumeIndex:scrolledPastThreshold:firstFullyVisibleIndex:)`, `ReaderKit/ReaderResumePositionResolver.swift`): the scroll reader records the content offset at open and reports the freshly-computed first FULLY-visible word (`firstFullyVisibleWordIndex` — first line not clipped by the top edge) ONLY if the user scrolled past a threshold (`scrolledPastThresholdPoints = 44pt` from the open offset); else it returns the incoming `resumeWordIndex` UNCHANGED (a no-op). (Active read-aloud / chunk playback still reports the live playback word. A FRESH open with no carried index — straight from the list — has no position to protect, so it reports the first-visible word so the first switch resumes correctly.) Entering scroll mode scrolls the carried word to 25% from the top (`scrollWord(_:toFractionFromTop:)`, clamped, no overscroll). Highlight/audio start playback at the word (follow-scroll centers it). RSVP reports/accepts its `currentIndex`. First open (no switch) keeps the persisted defaults (lastScrollOffset / lastWordIndex). Tests: `ReaderResumePositionResolverTests`.

**Both readers keep a column on a wide screen.** The scroll reader caps its prose
at `LunaLayout.readableWidth` (680pt), centered. RSVP needed more than a cap: its
focal column was a fraction of the VIEW, so on an iPad it flung the fixation point
a third of a metre from where the eye was resting, and the surrounding prose spread
past what one fixation can take in — which is the entire premise of the mode.
Everything in RSVP now lays out inside one centered `contentColumn` (capped at
600pt): the focal/ORP column, the phrase panel, the context labels, and the link
pill. Inside a carousel card neither cap ever binds, because the card is already
narrower than both.

**Audio session (PiP-safe)**: the silent speed readers NEVER instantiate a speech synthesizer or touch `AVAudioSession` (instantiating `AVSpeechSynthesizer` can interrupt Picture-in-Picture). RSVP's synthesizer is `lazy` (read-aloud only); `.playback` is activated only when read-aloud actually plays, and deactivated with `.notifyOthersOnDeactivation` on pause/exit (in both RSVP and `SpeechController`) so other audio/PiP RESUMES.

- **Scroll**: plain scrolling text (audio off) or read-aloud word-follow (audio on).
- **RSVP** (`ReaderKit/RSVPViewController.swift`): a centered speed reader with a **Words/Phrases sub-segmented control** sitting just below the top-level switcher (`subModeControl`, persisted in `ReaderSettings.rsvpMode`). Both sub-modes share the focal-word index (switching keeps your place), the scrubber / ±25-word skip / ±25 wpm controls, and read-aloud.
  - **Words**: the classic one-word-at-a-time display on the focal column with the ORP letter tinted inside a compact focus reticule, and word-length-aware timing (`RSVPEngine`). Context shows only while paused.
  - **Phrases**: a whole phrase shown over **two lines** in a glass reticule panel (`GlassStyle.focusPanel()`) in a **smaller proportional font** (`makePhraseFont`), with the surrounding prose **always visible above and below and updating as the phrase advances**. Phrase grouping + per-phrase timing come from `ReaderKit/ChunkPlanner.swift` driven by `ReaderKit/ReadingHeuristics.swift` (best-practice chunking: break at sentence/clause boundaries and before phrase-starting prepositions/conjunctions, never end a chunk on a determiner/preposition; dwell longer on long/complex/numeric words, skim function words). With read-aloud on, whole sentences are spoken and the **currently-spoken word is highlighted within the displayed phrase** (the phrase follows the speech word-to-word).
  - **Eye tracking**: an opt-in toggle in the reader's top-left corner pauses the SILENT speed reader when your gaze leaves the focal word (or the screen), with a dwell tolerance that shrinks the further the gaze travelled. Off by default; suppressed while read-aloud is on; overridden by pressing play while looking away. See `claudedocs/eye-tracking.md`.

The Reader carousel gives every card a stable title region using the normal 30pt
reader-title font and the saved page's asynchronously cached favicon (a globe while
loading). Scroll and Original/web-archive modes own two pixel-identical copies: a
permanent copy in the scroll view's top content-inset region and a pinned card copy.
Ownership of the title passes between them on a LATCH with a threshold at each end of
its travel, never one shared edge (`ReaderScrollPosition.pinnedTitleOwnsTitle`, in
LunaModels): the pinned copy takes over only once the scrolling copy has left the card
entirely — nothing is onscreen there, so its fade with surfaced card chrome is clean —
and hands back exactly where the scrolling copy is home again, the one offset at which
the two coincide, so the swap renders NO changed pixels and is applied unanimated. In
between, the pinned copy stays parked over the scrolling copy's approach. Sharing one
edge is what made scrolling back to the top look wrong: the pinned copy left while the
scrolling copy was still fully above the card, so the title blinked out and then slid
back in behind it. An
offset within that title region is normalized to zero when Scroll or Original persists,
so reopening shows the title in full instead of restoring a clipped fragment. That
canonical zero is converted back to UIKit's inset-relative top offset on restore
(`-adjustedContentInset.top`); applying it as raw zero would hide the title again. The
top inset never changes during either transition, so hiding chrome cannot move the
reader or its content offset. Both copies' backgrounds begin at the card's top edge,
while the favicon is vertically centered against one-, two-, or three-line titles.
The host applies that stable inset when each card controller is constructed, including
an off-window card staged for a ±2 scrubber eclipse, so its title is already present
with final geometry before it crosses onto the screen. The card's bounds are the
authoritative width for both copies: the nested scroll view can retain a provisional
screen-wide width for one parent layout pass, but that stale width must never reach
the visible title or change its line breaks after first paint.
**A title too long for the three-line cap is never truncated away — and is shrunk
before it is split.** `ReaderTitleOverflow.fit` (LunaReaderUI) sweeps nine type sizes
from the nominal 30pt down to 80% of it (`defaultMinimumScale`) and stops at the
LARGEST one whose whole headline wraps inside the cap, so a title that overruns by a
word simply comes down a notch instead of breaking across two type sizes, and a title
is never shrunk further than it has to be. Only a headline that overruns even at the
80% floor spills: the part past the cap is split off at its wrap point
(`ReaderTitleOverflow.split` — CoreText line ranges, so the break is never mid-word)
**at that smallest size**, so the head carries as much of the headline as the cap can
hold, and the remainder is shown directly below the title in smaller 17pt type, led by
an ellipsis, as the headline's continuation rather than a second one. Both copies fit
at the same card-derived width, so they stay pixel-identical and the handoff above
still changes nothing onscreen; the header simply grows, and the reader's top content
inset with it. Because the label's own font is the shrunken one, the sweep always
starts from a separately held nominal font (`baseTitleFont`) — running it against the
label would compound the shrink on every re-layout. VoiceOver still reads the whole
headline as one label.
RSVP has no scroll surface, so its pinned title stays visible through immersion and
its layout never changes. `ReaderHostFactory(includesArticleTitle: false)` still
suppresses the scroll reader's old attributed-string title to avoid a third copy.
Fullscreen, share-extension, and non-carousel readers keep the original inline title.

Reader and Downloader carousel cards share the same restrained glass rim: a 1.5pt
effect ring with a 0.5pt low-contrast highlight. Reader scroll chrome dismisses after
100pt of downward travel and returns after 50pt upward, enough to ignore tiny jitter
without making the reader reverse a large part of the page. Two positions override the
directional rule outright (`ScrollDirectionImmersionTracker`): at the very top the
chrome always returns, and it returns again as the end of the content lands on the
viewport's bottom edge. Because that bottom restore is about to take ownership, a
downward gesture near the end must NOT dismiss — the last half-viewport is a dead zone.
**That zone is capped at a quarter of the whole scroll range**, because it is a
fraction of the VIEWPORT measured from the end of the CONTENT: on an article only a
little longer than one screen the uncapped zone covered the entire scroll range, so no
downward gesture anywhere in the article could dismiss the chrome at all — every card
read as permanently surfaced. A long article is unaffected (the cap sits far above half
a viewport). Tests: `ScrollDirectionImmersionTrackerTests`.

Original mode applies the same stable top content inset directly to its WKWebView.
Archive **capture** enables content JavaScript and waits for the DOM/CSS/font/layout
signature to settle, because some publishers install their layout from deferred
scripts. Capture uses Luna's generic junk blocker, generic paywall cleanup, bundled
per-site cleanup, and per-host metering-script rules.

**The archive is captured from the HTML that produced the reader, and only ever from
that.** Ingestion writes the resolver's winning HTML to
`OriginalArchives/<id>-reader-source.html` (`ReadingListStore.saveReaderSourceHTML`,
excluded from backups, deleted the moment its `.webarchive` exists) BEFORE starting the
up-to-20s capture, so a surface that dies mid-flight still leaves the right capture
input behind — the share extension always dies, and `backfillMissingWebArchives` picks
the file up on the next app launch. A LIVE navigation is reserved for a save with no
recorded source at all (legacy rows; the Safari text-only action snapshot, which carries
no HTML); it is NOT a fallback for a failed capture. That fallback was the bug: whenever
the reader content came from a bypass the live page is a DIFFERENT document — the Paris
Review's Steinbeck interview reads out of a 49k-character pre-paywall Wayback snapshot
while the live page serves a 12k teaser under an un-dismissible subscribe card (598KB of
real article vs a 17MB archive of the wall) — so a live capture produced an "original"
the user never read and could not get past. With no archive at all, Original falls back
to the styled `ArticleContent` snapshot, which IS the version that drove the reader. The
archive.today reader records its extracted snapshot the same way, in case its own
web-view capture fails.
The generic WebKit CSS only targets structural wall containers—not arbitrary
`paywall` classes, because Condé Nast uses that class on the readable article
paragraphs themselves. DOM cleanup observes late child insertion for the full page
lifetime so a hydrated paywall cannot replace the article after first paint.
Archive capture keeps the post-layout DOM and injected CSS but strips publisher
`script` elements/resources, frames, inline event handlers, meta refreshes, and CSP
before persistence. Replay applies the same sanitization in memory to legacy archives,
adds a structural-wall/contrast safety stylesheet, and runs with content JavaScript
disabled in a non-persistent web session. It also verifies that the archive contains
the article that Luna extracted and checks the rendered article typography after load.
That content check (`WebArchiveSanitizer.containsReadableArticle`) is CONTIGUOUS, not a
word-set overlap: a metered teaser IS the article's opening, and prose reuses vocabulary
heavily enough that the Paris Review live capture — holding the first 28% of a
5,000-word interview — matched 68% of the distinct words sampled from the interview's
END, so the old "42% of the first 240 words appear somewhere" gate accepted it. Instead
it takes 48-character verbatim probes from blocks spread evenly across the whole saved
article (first block to last, inclusive) and requires ≥60% present; the same two
archives score 8/8 and 1/8. Matching compares letters and digits with all separators
dropped, so a `<br>` or `&nbsp;` the two sides serialize differently cannot fail an
identical passage. This also repairs items saved before the capture fix: an existing
archive of a wall simply stops being shown.
An absent, unsafe, content-mismatched, or visibly unstyled archive is replaced by a
self-contained HTML snapshot built from the saved `ArticleContent` (including local
images and links), with a no-network/no-script CSP and explicit light/dark palettes.
Original mode therefore never loads the live publisher URL and cannot flash readable
content before a paywall takes over.
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
- **On a wide screen a nested reader is a second CARD, not a tab.**
  `InlineReaderPlacement` decides, and every reader that can activate a link routes
  through one `InlineReaderOpener` — three copies of that decision is how a
  phone-only behaviour survives onto an iPad. `.overlay` is everything below, and
  is unchanged. `.column` (offered by a host with room for two columns; on the
  deck, `ArticleCardsViewController.hasRoomForColumn`) slides the outer card into
  the left column — restoring its card chrome and resting footprint rather than
  leaving it immersed — and pops the linked page as its own card on the right,
  where its nested layers keep stacking. The left card keeps every touch: scroll
  it, and a link tapped in it joins the RIGHT card's stack
  (`inlineReaderPushIntoOpenColumn`) instead of opening a third card. Closing the
  right card returns the left one to center.
  - A column is a **child** of its host, not a modal. A presentation container is
    a full-screen view that swallows every touch outside the presented frame —
    exactly the touches the card next door needs. `InlineReaderEclipseScene`
    already ran against any container, so the same eclipse plays either way
    (`animateColumnAppearance` / `animateColumnDismissal`).
  - Both columns are the same card: the left one is MOVED, never resized, so the
    right column is derived from it by one offset. That is what the half-width cap
    in `claudedocs/card-carousel.md` is for.
  - A column carries its OWN controls — one floating glass bar inside its card's
    bottom edge with close, the mode switcher, read-aloud and share. The deck's
    screen-level pill row belongs to the card next door, which is still being
    read, and read-aloud in particular has to be reachable on both cards for the
    exclusivity rule below to mean anything. The bar sits at the BOTTOM because
    the top of a reader is where the first line is.
  - **Two columns, one moving word** (`ReaderPlaybackArbiter`). Read-aloud was
    already exclusive — every in-app voice goes through the single
    `AudioPlaybackCenter`, which plays one item at a time. The silent speed
    reader's word timer is per-instance, so paired columns would both march, and a
    silent column would keep marching while the other was spoken. RSVP claims on
    both of its play paths, the scroll reader on both of its read-aloud paths, and
    the holder is asked to stop whichever engine it is actually running. It only
    ENFORCES while paired (`isPaired`, set by the deck): Luna deliberately keeps
    read-aloud going when you navigate away, so an unconditional rule would
    silence a backgrounded article the moment you opened another card.
  - While paired, the deck refuses to immerse, page or scrub, and the archive
    tray refuses to open — a paired layout IS the surfaced state. A rotation that leaves
    the screen too narrow for two columns closes the column rather than stranding
    it half off screen. Covered by `InlineReaderColumnTests` and
    `ReaderPlaybackArbiterTests`.
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
- `ReaderKit/RSVPViewController.swift` — hosts both sub-modes (`subModeControl`, default from `ReaderSettings.rsvpMode`). **Words**: word positioned so the ORP letter (tinted in the reading accent) sits on a fixed focal column (40% width), inside two three-character-wide hairlines that fade accent → gray → transparent (`GlassStyle.rsvpFocusReticule()`, `layoutFocusReticule`); context shows only while paused. Two 3pt inward ticks point from the lines toward the glyph, but no vertical line crosses behind it. **Phrases**: the chunk's words shown over two lines (`phraseLabel`, `numberOfLines = 2`, smaller proportional font, shrink-to-fit safety net) behind a glass `phrasePanel` (`GlassStyle.focusPanel()`), with `previousContextLabel`/`nextContextLabel` ALWAYS visible and re-filled on every advance (excluding the words in the focus panel); with audio on, `willSpeakRangeOfSpeechString` advances the displayed phrase to follow the spoken word and tints that word. Shared across both: tap = play/pause; scrubber (accent tint, pauses while scrubbing) — scrubbing/skip snap to the containing phrase in Phrases; **±25-word skip buttons**; ±25 wpm buttons (persisted via `ReaderSettings.baseWPM`, 100–900, default 300); the play/pause control pins both its layout and glass background to a true 60×60 circle; "% · wpm" status; light haptic at sentence/paragraph ends; resume via `ReadingListItem.lastWordIndex` saved on pause/close.
  - **Skip = ±25 words, playback-state-preserving** (`skip(by:)`): target = `RSVPEngine.skipTarget(currentIndex:by:wordCount:)` (pure, clamped to `0…lastWord`, unit-tested for both ends / ±25 / short / empty docs). It captures `wasPlaying`, tears down the active engine (WPM timer in silent mode, synthesizer in read-aloud mode) WITHOUT flipping the play/pause glyph, seeks (`currentIndex` + displayed word + scrubber + status), then restores the exact prior state — resumes from the new word (`scheduleNext`/`speakCurrentSentence`) if it was playing, stays paused otherwise. Never toggles play/pause, never restarts from the beginning, never desyncs the displayed word from the engine; the audio session is left untouched so read-aloud resumes seamlessly.

### Link-hold mini RSVP preview

Long-pressing an inline link in Scroll, or the current link pill in RSVP, opens
`LunaReaderUI/LinkRSVPPreview.swift`: a compact glass RSVP reader that exists only for
the lifetime of that finger unless locked. It appears and starts playback immediately
on the press, finger stationary — the interaction's delegate makes every ordinary
non-pan recognizer sharing the touch (including the host carousel's long-press) require
the link-only press's failure, so none can recognize mid-hold and cancel the preview;
pans stay independent so a drag that starts on a link still scrolls. The carousel does
not install `UIContextMenuInteraction` on card ancestors: its private stationary
touch-duration driver can gate action delivery for a descendant long press until the
finger moves. Card menus instead use the carousel's ordinary long-press recognizer and
programmatically present `UIEditMenuInteraction`, preserving Archive/Delete and media
menus without delaying the link preview. A small glass capsule
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

### Highlight, copy, share (plain-text selection)

A hold on plain text in the scroll reader selects the whole enclosing SENTENCE, not the
word UIKit would give you, and the selection callout carries a **Share** action ahead of
the system's own items. Both COPY and SHARE emit the same payload —
`ScrollReaderViewController.makeHighlightShareText`: the trimmed quote in literal double
quotes, a blank line, then the item's URL (a save with no real web URL — an imported
document, a synthetic scheme — sends the bare quote, since there is nothing to cite).
Two mechanics are worth knowing before touching this:

- **Copy is intercepted at the text view, not in the menu.** `QuotingTextView` (LunaReaderUI)
  overrides `copy(_:)`, which is where the callout's Copy, ⌘C and the accessibility action
  all converge — so one override covers every route and `editMenuForTextIn` can keep
  handing back `suggestedActions` verbatim. An empty selection, or a range the reader
  declines, falls through to UIKit's plain-text copy.
- **The sentence snap must not depend on recognizer order.** The reader's own long-press
  never moves the selection; it either expands what is already selected or arms the next
  selection change to snap (`sentenceLongPressAction`, pure and unit-tested; the expansion
  itself is `enclosingSentenceRange`, scoped to the pressed paragraph). Arming alone used
  to be the whole rule, which assumed this recognizer fires BEFORE the text view's own
  word-select — true in a full-screen reader, unreliable inside a carousel card, where the
  deck's context-menu interaction competes for the same press and the flag could end up
  waiting on a change that had already happened. A selection elsewhere in the article is
  stale and is never the one expanded. Tests: `HighlightShareTextTests`.

On a card this rides on the deck declining the press: `CardCarouselViewController`'s
context-menu delegate returns nil when the content claims the point, and
`ArticleCardsViewController.longPressSelectsContent` claims every press over a glyph, a
link, or an inline image — bare whitespace is what keeps the card's own Archive/Delete
menu. Nothing about the selection behavior is per-app: the article card is the same
`ScrollReaderViewController` in the central Luna app and in Luna Reader.

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
- **RSVP focus = accented ORP letter inside a compact focus bridge**:
  `GlassStyle.rsvpFocusReticule()` draws two hairlines roughly three monospaced
  characters wide. Each is brightest in the configured reading accent on the
  focal column, then fades through neutral gray to transparent at both ends.
  Two 3pt vertical ticks point inward from the lines toward the ORP glyph; the
  middle remains completely clear, so nothing runs behind the highlighted
  letter. Words mode (`layoutFocusReticule`; Phrases has its own panel) still
  reserves no separate reticule band. Scroll/chunk highlight
  remains an inline text-background tint in the accent.
- **The speed reader's vertical layout is one band, and the word sits at its
  MIDPOINT.** The band is the live space between the host chrome standing over
  the reader (`readingBandTop` = safe area + `topContentInset` + 18) and the top
  of the playback controls (`readingBandBottom`), so a tall in-card title header
  can never crowd the controls. `focalCenterY` is that band's midpoint plus a
  16pt downward lean (`focalCenterBias`). It used to be the **view's** midpoint
  + 24, which coincides with the band's only when the chrome above and the
  controls below are equally tall — in the action extension the bottom ~200pt go
  to controls plus the home-indicator inset against 18pt at the top, so the word
  sat ~110pt low under a void, and the trailing-context lane was squeezed to a
  single truncated line. Three consequences:
  - **The prose sits a third as far from the word as it used to, and the gap is
    measured from the word's OWN edge.** `focalHalfHeight` is the greater of the
    word label's line box and the reticule's reach (both scale with `wordFont`,
    which is sized from the screen width — a fixed clearance crowds the glyph on
    a wide screen); Phrases measures from the glass panel instead. On top of that
    sit `focalProseGaps`: 20pt above / 31pt below in Words (a third of the ~60 /
    ~92 the old flat 84 / 116 offsets left around a 30pt word), and Phrases keeps
    its own tighter 14/14. **The pill row — link preview or completion badge — is
    reserved only while something occupies it** (`FocalLanes.trailingTop`):
    holding an empty 36pt row open under every word is most of what made the
    lower gap large, and the row is nearly always empty (a link pill needs a
    linkified word; the badge only appears at the end, where the trailing prose is
    empty anyway). When a pill does appear the prose steps down inside the pill's
    own fade, so it slides rather than jumps.
  - **Each context lane is sized to its prose, not to the lane it may grow
    into** (`textHeight(of:width:)`). The preceding lane keeps its bottom against
    the focal band and grows upward (oldest words truncating off the top —
    `.byTruncatingHead`); the trailing lane keeps its top against the band and
    grows down. A label given the whole lane centres a short passage inside it,
    which read as a hole above the prose and a second hole below it.
  - **The controls lift off the bottom safe area on a roomy container** — 24pt
    base gap plus up to 40pt more, granted only while the band still clears
    `comfortableReadingBandHeight` (340pt) without it, so a short container keeps
    every point for the reading group. Because the group is centred on the band,
    it rises with them (`updateControlsBottomInset`, called first in
    `viewDidLayoutSubviews` — the lift moves the band's floor).
  - **`ReaderViewController`'s floating share circle hangs off the controls, not
    the safe area** (`updateFloatingShareAnchor` → `controlsClearanceAnchor`, an
    anchor rather than a measurement because a host reading the lift during its
    own `viewDidLayoutSubviews` would read it a pass late). The old fixed `-168`
    RSVP inset is gone. The circle still lands inside the trailing lane's
    rectangle, so the host publishes its frame as `hostOverlayFrame` and the lane
    gives up exactly that width (never narrowing past 140pt) rather than running
    its prose underneath. Tests, all in `ReaderScreenTests`:
    `testRSVPFocalWordRestsAtTheMidpointOfItsReadingBand`,
    `…ContextLanesAreSizedToTheirProse…`,
    `…ControlsLiftOffTheBottomOnlyWhenTheBandCanSpareIt`,
    `…TrailingProseYieldsTheRowOnlyWhileAPillOccupiesIt`,
    `…ShareButtonClearsRSVPControlsAndTrailingContext`.
- **Shared chrome carries a subtle per-app tint.** `LunaSurfacePalette` resolves
  Reader (173/181/246), Downloader (204/118/9), or Price Tracker (7/255/157)
  from the host bundle-id component, including that host's extensions. Liquid
  Glass bars/buttons use the base at 14% alpha; moon-horizon progress and custom
  scroll indicators use a gently contrast-tempered version of the same colour.
- **There is NO end-of-article share footer.** The old `ArticleShareView` ("Done reading? Share it." + a Share button, appended below the scroll reader's text and faded in above RSVP's controls on finish) is gone, along with the scroll reader's `onShareFooterVisibilityChanged` hook that faded `ReaderViewController`'s floating share button out while the footer was on screen. Sharing is reached from the reader chrome only (the floating/nav-bar Share button, below), which is now always visible. The scroll reader still appends a fixed completion lane after TextKit's measured text bottom (the Read pill sits inside it — `layoutCompletionArea`), and the reserved bottom inset clears that lane plus the read-aloud footer without feeding `contentSize` back into their position.

## Reader share sheet (the share button) — Feature C

The reader's nav-bar/footer Share button routes through `ReaderShareProviding.shareMenu` / `.presentShareSheet`. In the main app, `AppReaderShareProvider` builds one `ReaderShareSheet.rows(…)` list (`LunaSocialUI/ReaderShareSheet.swift`) and hangs it off the button as a native `UIMenu`, falling back to its own bottom sheet for entry points that aren't a button we own: **Copy link** (`SendToFriendSheet.copyLink`), **Share link** (`SendToFriendSheet.shareLink`), **Send as email** (`SendToFriendSheet.present` — recent-recipient bottom sheet, or the full picker when there are no past sends), and — for readable articles/documents only — **Export as…**, a submenu of EPUB / PDF / Word Document / Text (`ArticleExportService.presentShareSheet(_:for:…)`, see article-export.md). Share link hands the system share sheet a Reader/Downloader App Clip invocation URL from `LunaAppClipInvocationURL` when configured; Copy link always copies the plain source URL. Rows are a pure list (testable visibility/actions); tapping a sheet row dismisses first, then runs the action or presents the nested export sheet.

## Reader App Clip

`LunaReaderClip` is an App Clip target embedded by the Reader app. It accepts the same
invocation shape as the Downloader clip (`?url=`, `?source=`, `?sourceURL=`, `?u=`, or a
fragment) via `LunaAppClipInvocationURL.sourceURL(from:)`, runs the shared
`IngestPipeline`, and presents the normal `ReaderViewController` with `forceMode: .scroll`,
`persistsModePreference: false`, `marksOpenedOnLoad: false`, and `shareProvider: nil`.
That keeps the clip read-only: no saved-list writes, no Save affordance, and no reader share
button (iOS does not provide an API for an app/app clip to launch its own share extension as
a share target). The source web URL is a normal shareable `ReadingListItem`, so the
standard Original-mode capability path still appends Original alongside Scroll and RSVP.
Original uses the frozen archive when one exists and otherwise the extracted local article
snapshot; it never reopens the publisher URL.

## Share-sheet reader experience

Fixed behavior: the **share extension** (`com.apple.share-services`) always saves + dismisses, for every URL. The **"Read in Luna" action extension** (`com.apple.ui-services`) routes via `ShareViewController.presentSavedOrReader`:
- **Article URLs** → `ShareKit/ShareReaderViewController` fetches + extracts (`ArticleFetcher` + `ArticleExtractor`) and presents the **real** `ReaderViewController` with a lightweight **`ExtensionReaderShareProvider`** (Feature D) — so the reader's own share button works: it offers a friend picker (friends read from the App Group via `ExtensionFriendsReader`; the send is QUEUED to `pendingFriendShares.json` via `PendingFriendShareWriter` for the main app to deliver — no CloudKit in the extension) plus a link share. No suggestion engine in the extension, so no one-tap suggested send. The action ext keeps its OWN last-used mode in `ShareKit/ActionReaderMode` (private `UserDefaults.standard`); `ReaderViewController(persistsModePreference:false, onModeChange:)` writes there, not the shared `ReaderSettings`. If fetch/extract fails, `presentFailure()` shows a red error state (warning glyph + message) with the exit available.

**Exits.** Every extension screen whose bottom-right corner is free carries the same
floating Liquid Glass exit (`ExtensionExitButton`, LunaDesignSystem) instead of a
navigation bar holding one "Done": the action extension's status/error screen and
`ShareReaderViewController`'s loading / saved / failure states — which hide the host's bar
for exactly that reason. A checkmark where something WAS saved,
an `xmark` where the screen is an error (never a checkmark over a failure). Three screens
deliberately keep their own: the **media save screen**, whose exits are a stack of
full-width pills on the bottom safe area (Done under Delete, with the floating share
circle above them — see `claudedocs/media-download.md`); the in-sheet **reader** (its bottom-right is the
floating share control, and two hovering circles in one corner is worse than one bar
button — `ShareReaderViewController.doneButton` documents this); and the extension **price
editor** (its bottom-right is the alert-threshold footer, and it is the same object in-app,
where the header control is the one the user already knows). The archive-CAPTCHA reader
keeps its own bar buttons, so `presentArchiveReader` restores the navigation bar before
handing the stack over.

**One hand-off, not three steps.** The extension surfaces show exactly ONE loading state — the
host's own (`ShareViewController`'s centred spinner + `ArticleLoadingStatusCycler` label) — and go
straight from it to the finished article. `ExtensionArticlePresenter.presentReader` no longer hands
the host a `ShareReaderViewController` to display *its* loading screen: it awaits
`ShareReaderViewController.preparedReader(url:mode:content:store:…)`, which persists the content,
settles the image layout, and returns the built `ReaderViewController` (Done already installed).
Only then does `presentModally` run, tearing the host's spinner down as the article appears. Before
this the surface visibly reset mid-load — the spinner restarted a couple of points higher in a
second screen, Done arrived a beat before the text, and only then did the reader swap in.

**Image layout is settled BEFORE the article is shown**, so nothing reflows under the reader's
feet. `preparedReader` → `settledImageLayout` resolves the images already on disk, then awaits
`ArticleImageDownloader.downloadUnknownSizeImages` for the images whose dimensions the page never
declared — precisely the ones `ArticleTextRenderer.attributedImagePlaceholder` cannot reserve space
for, and therefore the ones whose late arrival shoves the text down. Images WITH declared sizes are
not waited on: their placeholders already hold the right box, so `fetchMissingImagesIfNeeded` fills
them in behind the reader without moving a word. The wait is bounded by
`imagePreparationTimeout` (8s) and a timeout still keeps whatever landed (a second local resolve),
so an unreachable image CDN can't strand the sheet on a spinner. `settleImagesOverride` substitutes
the download in tests (`ExtensionReaderPreparationTests`, `SurfaceParityTests`) so a fixture's
`<img>` tags never pull the suite onto the network. The standalone and archive→reader paths run the
same settling behind `ShareReaderViewController`'s own spinner.

All three reader modes, audio (foreground only), and the inline split-web link viewer work; a Done button exits the extension. Resume starts from the first fully-visible word (`ScrollReaderViewController.firstFullyVisibleWordIndex`).

**The extension's header height is MEASURED, never assumed** (`ExtensionNavigationController`,
LunaShareSurface). The surface's one navigation container is a CHILD view controller living in the
host's window, and a modern navigation bar draws over the content it titles — between those two, the
screen underneath can be handed a safe area its own bar still covers. Everything measured from that
safe area then starts too high: the article opened with its title tucked up under the bar, and the
scroll indicator began its track behind it. So the container measures the bar after every layout and
adds whatever it still overlaps to the visible screen's `additionalSafeAreaInsets.top` — zero on a
runtime that already accounted for the bar, and zero while the bar is hidden (the loading / saved /
failure states hide it), so it can only push content out from under a bar that is really there.
Two matching rules in the scroll reader itself: a fresh open with no saved position rests at
`-adjustedContentInset.top` rather than UIKit's zero (which IS the visual top only when no chrome
insets the content), and the `HorizonScrollIndicator` track is given the extent the reader SHOWS —
just below the top chrome down to the top of the bottom safe area (plus the read-aloud footer while
it is up). The indicator's own default mirrors the scroll view's content insets, and this reader's
bottom inset reserves the completion lane, which ended its track well over a hundred points short of
the screen. Tests: `ExtensionScrollGeometryTests`.

**Deep links**: `lunareader://read?url=…` (`LunaDeepLink`) opens the app and loads that article in the reader (`SceneDelegate.openReader`). Schemes are per-app now — `lunareader://` (Reader), `lunadownloader://` (Downloader), `lunapricetracker://` (Price Tracker), via the per-target `LUNA_URL_SCHEME` build setting — and parsing accepts any of the three. The in-app "Share Link…" shares this link. (A custom scheme opens the app only when installed; App-Store fallback would need a Universal Link.)

## Inline images

Extractor emits `.image` blocks (`imageURLString`) for article `<img>`s — token-exact junk filter (ad/tracking/logo/etc; substring matching would reject WordPress `/uploads/` URLs) and skips declared-tiny (<140 px) raster art plus SVG, while retaining GIFs. Open Graph/Twitter/JSON-LD lead art is promoted to block zero — but ONLY when the body has no image of its own within roughly two screen heights of content (`leadImageProseBudget`, 1400 chars of block text; an image block short-circuits the count). A cover stacked directly above, or a few lines from, the article's own opening photo reads as a rendering glitch, whether it's the same picture or a different one, so in that case the body is left exactly as extracted. When the lead art only appears further down it is MOVED to block zero rather than shown twice, so an animated GIF can be the reader's lead/header image. `ArticleImageDownloader` downloads up to 30 images (≤12 MB raw each, ≤40 MB stored per article) into the Articles dir (`imageFileName`). Static images are downsampled and transcoded for fast decoding; animated GIF/APNG files retain every frame. `.gif` URLs use an animation-safe `Accept` header because WordPress image CDNs otherwise negotiate animated WebP, which the old static transcode flattened to frame zero; if a CDN still returns animated WebP, ImageIO converts the sequence to GIF. Reopening an older save automatically unlinks/refetches a legacy frame-zero JPEG for a `.gif` source. `ArticleTextRenderer` keeps a downsampled first-frame `NSTextAttachment` for stable TextKit layout and snapshots; `ScrollReaderViewController` overlays an `AnimatedArticleImageView` driven one frame at a time by ImageIO, enabling playback only near the visible viewport to bound memory/CPU. RSVP ignores image blocks (no tokens). Tests: `AnimatedArticleImageTests`, `ArticleExtractorTests.testRetainsGIFBodyImageAndCanPromoteGIFToLeadImage`.

## Chapter marks (the page's own table of contents)

A long blog entry often opens with a table of contents: a list of `#fragment`
links into headings further down the SAME page. Luna preserves those and makes a
row scroll the reader; everything lives in
`LunaHTMLClassification/InPageAnchors.swift` plus a new block kind,
`ArticleContent.Block.Kind.tableOfContents`.

**Why it needs its own pass.** Nothing else would have kept it: both extraction
layers strip `<nav>` outright, and `cleanConditionally` deletes exactly a ToC's
shape (a `<ul>`/`<ol>` under 500 chars that's >80% link text). So
`InPageAnchors.prepare(document:baseURL:)` runs on the freshly parsed document
BEFORE any stripping: it collects the fragments the page references, normalizes
the `<a name="x"></a>`-before-the-heading idiom by hoisting the id onto the
element it labels, and marks every qualifying container with `data-luna-toc`.
That marker is what the strip loop and `cleanConditionally` skip. It is set on
EVERY qualifying element in a nesting chain (a `<nav class="toc">` AND the `<ul>`
inside it) because each must survive on its own account; rows are emitted from
the OUTERMOST one, so the list's label ("Contents", "In this article") comes
along as an unlinked row. A non-qualifying ancestor is deliberately still
strippable — a ToC parked in a sidebar `<aside>` is GIVEN UP rather than dragging
the newsletter box and popular-posts rail into the article.

**Detection errs toward omission** (a missed ToC reads as an ordinary article; a
false positive turns prose into furniture that RSVP and read-aloud skip): ≥3
distinct fragments that resolve to a real element, ≥80% of the container's links
in-page, >55% of its text inside those links, ≤3000 chars total. That rejects a
related-articles rail (outbound hrefs), a two-link "jump to recipe" bar (too
few), prose peppered with footnote markers and a footnote list with `↩` back-links
(link TEXT too small a share), and site navigation carrying one anchor.

**Rows are built from the anchors, not the `<li>` walk** — a nested `<li>` has a
block ancestor, so the generic walk would fold a two-level ToC's sub-entries into
their parent's bullet. Each row is one `.tableOfContents` block whose single
`ArticleContent.Link` carries `anchorID`; the destination block carries the same
string in `Block.anchorID`. Lookup is by id (`ArticleContent.blockIndex(forAnchorID:)`),
never by index, so moving the lead image to block zero can't misdirect a jump.
`InPageAnchors.resolvingAnchors` runs LAST in `extract()`, after every trimming
pass, on the blocks that actually survived: a row whose destination was trimmed
loses its link (plain text beats a tap that reopens the live page), and a ToC left
with fewer than 2 working rows is dropped whole. The junk heuristics are also
taught to leave an identified ToC alone — it can't be popped by `reverseTrim`,
can't be read as a mid-article recirc line, and a row reading "More on this" can't
fire the recirc terminator and truncate the article.

**In-page links in PROSE get the same treatment** (a footnote marker jumps to the
footnote), and `ArticleContent.outboundURLs` excludes them — crawling one would
refetch this very article. An unresolvable prose anchor just loses its `anchorID`
and behaves like any other link.

**The reader side.** `ArticleTextRenderer` styles a ToC as a compact indented
16pt list (its label semibold/secondary, unindented) and attaches
`.lunaInPageAnchor` — the destination's `anchorID` — alongside `.link`.
`ScrollReaderViewController.textView(_:primaryActionFor:defaultAction:)` checks
that attribute FIRST and calls `scrollToInPageAnchor` instead of opening
anything, at every reader depth (the check precedes `onLinkActivatedWithRange`,
so inline/RabbitHole hosts never see an in-page tap). The jump lands 8% from the
top via the shared `scrollRange(_:toFractionFromTop:animated:)` primitive
factored out of `scrollWord`, clamped so the last section can't overscroll.
**A tap during Phase 1 is the COMMON case** — a ToC sits at the very top and its
destinations are past the 700-char prefix — so the jump is parked in
`pendingAnchorBlockIndex`, `prepareFullContent()` is kicked, and the Phase-2 swap
honours it in place of the offset it just restored (cleared by
`resetTransientState` so it can't survive into a recycled reader). Link HOLDS
don't offer the mini RSVP preview for an in-page jump (`previewableLinkURL`),
which would load this same article; `link(at:)` itself still reports the hit so
the card keeps treating a row as interactive content.

**Never read aloud, never in the word stream.** `Block.isReadableProse`
(`kind != .tableOfContents`) is the single predicate four consumers share:
`RSVPEngine` and `WordMap` both skip those blocks — they must do it TOGETHER or
every index past the ToC would mean a different word in each reader (the ToC does
render, so it HAS a `blockTextRanges` entry; the skip is on kind, not on a
missing range) — `SpeechController.speakableBlocks` filters them, and
`AudioTrimHeuristics.signal` drops them at `.high` precision so the global
50%-cap degradation can't reinstate them. `RSVPEngine` also drops the URL of an
in-page link so no link pill offers to reopen the current article.
Note that image CAPTIONS are ordinary `.paragraph` blocks and ARE still in the
RSVP stream — only the audio script drops them (`captionCreditReason`).

Other renderers: the offline snapshot (`SavedArticleSnapshotRenderer`) and the
EPUB (`EpubBuilder`) are each ONE document, so both emit `id=` on anchored blocks
and rewrite a row's href to `#anchor` — chapter marks keep working offline and on
a Kindle. Mail keeps the absolute href, so a row opens the live article at that
section. Fixture: `UITestState.tableOfContents`. Tests:
`InPageAnchorTests` (18 — detection, the shapes that must NOT match, omission,
markup idioms, legacy decoding), `TableOfContentsWordStreamTests` (7 — the
four-consumer skip + index-space alignment + id lookup).

## Article extraction (`ReaderKit/ArticleExtraction.swift` + `ArticleExtractor.swift`)

**Stage-2 component (`ArticleExtraction`).** The ONE place HTML becomes content AND is judged readable. Wraps the pure `ArticleExtractor` parser and exposes: `extract(html:baseURL:)`, `extractFromJSONLD(html:baseURL:)`, the shared `fetchAndExtract(baseURL:fetch:) -> ExtractedArticle?` helper (one fetch-then-extract for the whole pipeline — the byte-identical `ArticleResolver.extractedContent` / `BypassRunner.extracted` duplicates were deleted), and the SINGLE predicate `static isReadableArticle(_:html:)`. That predicate (`bodyTextLength >= ArticleContent.readableBodyThreshold && !PaywallDetector.looksPaywalled(content:html:)`) consolidated the three former duplicate readable/locked checks — `ArticleResolver.isReadable`, `BypassGate` step 3, and the implicit `!looksPaywalled` inside `ArticleContent.hasReadableBody`. It is HTML-aware (folds in the schema.org lock), so the lock can't be skipped via a text-only path. `ExtractedArticle { content, sourceHTML }` replaces the old `(ArticleContent, String)` tuple. `ArticleContent.hasReadableBody` is now a thin text-only (`html: nil`) call into the predicate. Tests: `ArticleExtractionTests` (per-site readable + paywalled-stub table for nytimes/washingtonpost/wsj/smh.com.au; the HTML-lock false-negative guard; long-article-quoting-a-gate-phrase policy locked).

Layered readability: **refined** (aggressive junk-by-class stripping — footers, share/social bars, related rails, **comments**, **subscribe/paywall promos**, newsletter prompts) → **basic** (structural tags only) → JSON-LD `articleBody` → raw body text. `extract()` **trusts a substantial refined result** (≥600 chars) even when `basic` is much larger; the `refined*3 ≥ basic` guard only arbitrates a *medium* refined (350–600). This is the fix for archived WSJ/FT snapshots, where a long reader-comments thread + subscription gate hold more `<p>` text than the article — the old guard fell back to the unstripped `basic` pass and surfaced gate + comments instead of the body. `bestContainer` also **prefers an explicit article-body container** (`[itemprop=articleBody]`, `[class*=article-body|articleBody|article-content]`, …) with ≥400 chars before paragraph-scoring, so both layers target the prose.

**A structural line break is worth a space.** `makeBlock`'s walk concatenates the text
nodes it finds, so any element that ends its line without carrying a whitespace
character used to be a zero-width join: `<br>` contributed nothing, and a `<p>` nested
in a `<blockquote>` is walked as part of that one quote (it's skipped as its own block by
`hasBlockAncestor`). The Paris Review separates the paragraphs of a quoted passage with
`…his feeling.<br><br>The discipline…`, which reached the reader as "feeling.The
discipline" — four such joins in one quote. `lineBreakingTags` (`br`, `hr`, `img`, and
the block-level containers) therefore synthesizes a space on entering and leaving the
element, collapsed against whatever whitespace is already there so real markup still
yields exactly one and it never leads a block. Inline tags are excluded — a boundary
inside `<em>un</em><strong>believable</strong>` would split the word. Appended between
text nodes, so link ranges recorded earlier don't move and later ones shift with the text
they name. Tests: `ArticleExtractorTests.testBRBetweenSentencesBecomesASpace`,
`testNestedParagraphsInAQuoteAreSpaceSeparated`,
`testLineBreakCollapsesAndKeepsLinkRangesAligned`, `testInlineMarkupDoesNotGainASpace`.

**Paragraph-like `<div>`/`<section>`**: scoring and block extraction treat a `<div>`/`<section>` with **no block-level child element** (pure inline/text) as a paragraph — `isParagraphLikeContainer` / `paragraphLikeElements`. archive.today rewrites the captured page so **every body paragraph is a styled `<div>` with no `<p>` at all**; without this the whole body is invisible (extraction collapsed to the title + a stray summary box, ~1k chars). Div/section paragraph blocks must clear the same **>20-char** bar scoring uses, so short UI chrome (timecodes, "Up Next", labels) isn't emitted; explicit `<p>`/heading/list/quote tags keep any-length behavior.

**Player + hidden chrome**: refined also strips `[class*=video|player]`, `[id*=video|player]`, `[aria-live]`, `[role=slider|menu|menubar]`, and **visually-hidden / sr-only** elements (`removeVisuallyHiddenElements` — `clip:rect(1px…)`, `clip-path:inset(50%)`, 1px boxes) so an embedded video player's chrome and screen-reader labels don't leak once div-text is captured.

**A wrapper that HOLDS the article is layout, not the rail its class names.** Junk
classes are matched by SUBSTRING, which also hits the layout wrapper that merely makes
room for the thing it names — and removing that removes the story, zeroing the refined
layer so the *untrimmed* `basic` layer wins arbitration and every ad label and recirc
rail it keeps reaches the reader. Two shapes of this: a class on the page root
(WordPress emits `sidebar-right has-sidebar` on `<body>`; New Statesman), handled by
`isPageRoot`; and a grid wrapper naming its own columns (NY Post lays an article out in
`<div class="layout layout--sidebar">`, whose two columns are the story and the sidebar
— refined returned **13 characters**), handled by `articleWrapperChain`: score the prose
container BEFORE stripping and spare its **strict** ancestors. Strictness is the safety
property — on a comment-heavy page where the thread outscores the story, the thread's own
container still matches `[class*=comment]` and is still removed; only the shared layout
wrappers above it survive, and each of THEIR junk children is still matched individually.
So the rule never keeps junk that used to go; it replaces "delete the wrapper" with
"delete the wrapper's junk". Tests:
`ArticleBodyFurnitureTests.testLayoutWrapperNamingASidebarDoesNotDeleteTheArticle`,
`ArticleExtractorTests.testLayoutClassOnBodyDoesNotDeleteTheDocument`.

**Ad labels and in-body recirc rails are shape rules, applied to WHICHEVER layer wins.**
`basic` runs no trailing-junk trimming at all, so the position-independent rules were
hoisted out of refined's `trimTrailingJunk` and now also run once on the chosen layer
(alongside the comment-tier terminator). Left in refined only: the recirc terminator tier
and the reverse trim, both of which lean on refined's class stripping to stay free of
false positives. The two rules:

- **Ad label** (`adLabelPhrases`, Readability's `adWords`): a block whose WHOLE text is a
  slot's own caption — "Advertisement", "Sponsored content", "Story continues below…".
  NY Post ships nine `<p class="ad__label">Advertisement</p>` inside `<div class="ad">`,
  which no `advert`/`sponsor` substring matches. Whole-text matching is what leaves prose
  that merely discusses advertising alone.
- **In-body recirc module** (`removeInlineRecircModules`): a publisher's ad for its own
  content — NY Post's "Explore More" card rail dropped between two body paragraphs —
  recognised by SHAPE rather than by the wrapper's class, and removed IN PLACE because the
  article continues underneath it. A run of adjacent blocks that are essentially nothing
  but hyperlink (`isFullyLinkedCard`: >0.9 link density, <200 chars, no in-page anchors),
  optionally under a short label. The false positive to avoid is a genuine link roundup
  ("five posts to read this week"), so two gates: a run of **≥2** all-link blocks is a
  rail on its own evidence, while a **lone** one goes only under a recirc label
  (`recircLabelPhrases`, matched exactly). In a roundup the linked headings are separated
  by the author's prose, so every run is length 1 and unlabelled. A dropped multi-block
  run also takes a preceding short bare heading with it, whatever the section is called
  ("More from Business") — that's what stops an orphan label being left behind.

**Captions: `.caption` blocks — rendered, never read.** `figcaption` was in no selector,
so the reader silently lost every caption on every page (twelve on the NY Post article).
Detection is structural: a `<figcaption>`, plus any text inside a `<figure>` (WordPress
emits `<figure><p class="wp-caption-text">`). `figcaption` joining `blockTags` also stops
a `<p>`/`<img>` nested in a caption being emitted twice, and `select`'s document order
puts the caption directly after its image. A caption is NOT prose: `isReadableProse`
excludes it, so RSVP, `WordMap`, `SpeechController` and the audio script all skip it and
stay in one word-index space — a photo credit is never flashed mid-sentence or spoken
aloud. Three trimming rules learned the kind or would misfire: a caption is not the strong
paragraph that shields a trailing image dump, it can neither arm nor trip the recirc
terminator (a credit reading "Trending Now / Reuters" is an agency, not a rail), and the
reverse trim must not pop a closing caption off the end and orphan its picture (photo
credits carry "©", one of that pass's junk phrases). Every renderer has a case: scroll
reader (smaller, dimmer, tucked under the image), saved snapshot, X-post HTML, EPUB, PDF,
Markdown, plain text, mail. Tests: `ArticleCaptionTests`.

Regression tests: `ArticleExtractorTests.testArchivedArticleBeatsSubscriptionGateAndComments`, `…testDivBasedArticleBodyExtractedWithoutPlayerChrome`, `ArticleBodyFurnitureTests`, `ArticleCaptionTests`.

## Hard-paywall resolution & archive reader

**Paywall detection** is one shared, content-based `PaywallDetector` (ReaderKit) — NOT a host allowlist (so a reader logged in via their browser gets the full article and isn't flagged): **gate markers** ("login or signup to continue", "subscribe to read", …) flag a wall at any body length; **weak markers** (subscribe now, support local journalism, …) flag only a short body; and `htmlDeclaresLocked` reads schema.org `isAccessibleForFree:false` / an `article:content_tier` meta. `ArticleContent.looksPaywalled` and `ArticleResolver` use it; a JS mirror lives in the Safari extension's `content.js` (keep the marker lists in sync). Tests: `PaywallDetectorTests`.

**The generous preview: a gate that TRUNCATES (`TruncationGateDetector`).** Every signal above keys off a THIN body or publisher metadata, so a publisher who serves a long readable preview and then cuts the prose off server-side reads as a complete article. `theparisreview.org` ships ~12k characters of a ~50k-character interview with no `isAccessibleForFree`, no `article:content_tier` and no JSON-LD `articleBody`; the extractor also strips `[class*=paywall]` nodes, so the gate's own "Already a subscriber? Sign in" wording is gone before the text-marker scan runs. So this detector reads STRUCTURE from the source HTML: a wall container (`paywall`/`regwall`/`article-gate`/… in class or id) that carries a high-precision gate marker, holds under 800 characters of prose itself (the WSJ `.paywall … PaywalledContent` wrapper exemption, mirroring `ArticleExtractor.isArticleHeavyPaywallWrapper`), follows >= 1200 characters of prose, and ENDS the container it sits in (<= 20% as much prose after it as before). The before/after comparison is SCOPED to the smallest ancestor holding the preview — measured document-wide, a publisher's "read next" rail swamps it (the Wayback capture of that page carries 11k characters of a DIFFERENT interview below the wall). It folds into `PaywallDetector.looksPaywalled(content:html:)` at ANY body length (unlike `htmlDeclaresLocked`, which only counts under `shortBodyThreshold`), which is the whole point. Deliberately narrow — a false positive spends a pointless bypass and can downgrade a readable save to `.needsArchive`; the negative cases it must keep clear are sign-in chrome on a free article, an unlocked body inside a node that merely NAMES the paywall, and a wall left mid-body on a capture the Safari extension already unlocked. Prose is counted over `<p>` only, so a div-paragraph publisher simply isn't detected here. No `content.js` mirror is needed: the extension scans `document.body.innerText`, which still contains the gate CTA. Tests: `LunaHTMLClassificationTests/TruncationGateTests`.


**Shared pipeline (`ReaderKit/IngestPipeline.swift`).** The SINGLE dep-free entry `IngestPipeline.process(_ input: IngestInput, timeout:…, …) async -> Outcome` runs the WHOLE pipeline ONCE — (1) `URLUnwrapper.unwrap` once; (2) `Classifier.classify` (deterministic table FIRST — platform/video/document decided before any fetch, so a video can never reach extraction); (3) per-kind processing: product detection (→ `Outcome.product`, never paywall-bypassed; `IngestInput.forceArticle` forces the article path for "Read instead") → gated article resolution via `ArticleResolver.resolve` → `.article` / `.needsArchive` / `.failed`. The whole call is wrapped in ONE overall timeout (`processTimeout = 28s`) so it can never hang. **All six surfaces call this exact entry** and differ ONLY in their `OutcomePresenter` (the protocol's exhaustive `Outcome` switch, no `default`): `ReadingListIngestor.ingest` → `IngestorOutcomePresenter` (main app — list state + images/cover), `ShareViewController` (both extensions) → `ShareOutcomePresenter` (inline reader / saved-non-textual / archive reader / saved checkmark / error), `ShareReaderViewController.ingestAndPresent` (action-ext reader, takes the pre-computed `Outcome`), plus app intents + incoming friend share via the ingestor. `render` defaults nil in the extensions (no WebView — the "spins forever" fix); the main app injects `WebViewPriceRenderer`. Replaces the deleted `ArticleIngestDecider`. Tests: `IngestPipelineTests` (parity: same `IngestInput` across all `CaptureSource`s → same `Outcome`; platform/video recognized before extraction; overall-timeout never hangs) + `OutcomePresenterTests` (outcome→UI mapping; `.failed` never "Saved").

**Deterministic direct fetch (Stage 2).** `ArticleFetcher.fetchHTML(from:)` now uses ONE UA (Safari) with no fallback chain — the bytes a normal reader sees, so the paywall judgment is reproducible run-to-run. The Googlebot crawler trick is NOT the default read; it is the explicit `.userAgent(.googlebotDesktop)` bypass strategy (`CrawlerAgent.googlebotDesktop`, the de-duplicated Googlebot UA). Tests: `ArticleFetcherTests`.

**Data-driven bypass pipeline.** `ArticleResolver.resolve` is now: direct fetch (reusing `prefetchedHTML` when supplied) via the shared `ArticleExtraction.fetchAndExtract` → if `isReadableArticle` return → else build ONE `BypassPlan.make(for:directHTML:)` and run its `silent` leg (bounded by `BypassPlan.silentChainDeadlineSeconds = 20`) until one yields a readable, non-locked `ExtractedArticle` → else `resolution(...)`. A nil OR non-readable/locked result is skipped and the first readable one WINS (tested in `ArticleResolverTests`: advance-past-failing, reject-unreadable-and-advance, fall-all-the-way-to-paywalled). Every plan's silent leg now LEADS with the two Wayback strategies (`.waybackRaw` then `.waybackPrePaywall`) — they are silent and CAPTCHA-free, so they belong ahead of any user-visible WKWebView flow, and until this landed the selector emitted NONE of the silent archive strategies (`.waybackRaw`/`.jinaReader`/`.ladderProxy` were runner-only code exercised solely by unit tests, and every plan went from the site rule straight to the browser tier). The legacy trailing `fetchArchivedHTML` last-silent attempt was DELETED (`.waybackRaw` covers Wayback in every plan; `archive.ph/newest` belongs to the WKWebView terminal flow) — removing the duplicate Wayback hit + near-always-failing archive.ph GET is the NYT/WSJ "no silent strategy worked" speed fix; `fetchArchivedHTML`/`fetchArchiveTodayHTML` were removed from `HTMLFetching` and all conformers. The `.readable/.paywalled/.unreadable` → `Outcome` mapping (in `IngestPipeline`) is unchanged.

**The silent tier FANS OUT, and resolves by plan order (`ArticleResolver.firstQualifying`).** The strategies are independent GETs against different servers (the publisher, the Wayback index, an archive replay), so running them one after another made the wall clock their SUM. Measured on the reported WSJ save: the publisher was never the problem — the direct read and the site rule's Drudge-referer read both 401'd in under 0.2s — but the two Wayback legs cost ~30s between them against a 20s chain budget and `IngestPipeline.processTimeout = 28`, and the action extension sat on a spinner that looked hung. All silent attempts now start together (the site rule's own request leg and its forced JSON-LD reconstruction included — same tier, so same fan-out) and the tier resolves by **list order, not completion order**: a cheap-but-weaker strategy that answers first still cannot outrank a better one ranked above it, so the OUTCOME is identical to the old serial walk while the wall clock is the max instead of the sum. Losers are cancelled once a winner settles. End to end, WSJ went from a 20.3s worst case (clipped by the chain deadline) to ~3–10s. Tests: `ArticleResolverTests.testSlowerHigherRankedStrategyStillWins`, `.testSilentStrategiesRunConcurrently`; and because the tier is concurrent, `MockArticleFetcher.calls` is lock-guarded and assertions on it compare SETS, never positional sequences.

**The Wayback INDEX, not the archive, was the slow part.** CDX either answers in about a second or effectively stops answering: three consecutive `.newest` lookups of one WSJ article measured 16s (timed out), 1.7s and 14s, while the Availability API answered the same question in ≤0.6s every time and the replay download took ~1s. So `fetchWaybackRawHTML` **races** them (`resolveNewestSnapshot`) instead of reaching for the fallback only after CDX has spent its whole timeout: CDX stays preferred — it filters out tiny stub captures and addresses the raw `id_` replay — but once a usable Availability snapshot exists it gets `waybackIndexGrace = 1.5s` more and then loses (falling back to IA's rewritten replay, which for JS-heavy sites is the better capture anyway). With no Availability answer there is nothing cheaper to fall back to, so the grace timer never starts and CDX is waited out. Index timeouts are now sized like index lookups — `waybackIndexTimeout = 8s`, and `waybackSpeculativeIndexTimeout = 4s` for the pre-paywall long shot — rather than like content downloads (they were 15s). **Both race legs must be STRUCTURED group children**: `withTaskGroup` implicitly awaits every child before returning, so the first cut — which wrapped each leg in an unstructured `Task` and awaited its `.value` — hid the requests from `cancelAll` and went on blocking the full 8s on the stalled CDX request it had just decided to abandon (grace expired at 1.5s, returned at 8.0s). Don't reintroduce a `Task { }` there.

**A trusted Safari capture is a FLOOR, not a winner.** `trustsPrefetchedHTML` (the "Read in Luna" hand-off) accepts the capture on body length alone, because the already-unlocked page the user is looking at usually still carries a stale `isAccessibleForFree:false`. But when such a capture ALSO still reads as locked, the resolver keeps it as a FALLBACK and first spends the silent tier — a rule host's ONE rule request fetch, then the plan's silent leg: Safari can apply a rule's script-blocking half but cannot spoof the request User-Agent, so a partially-unlocked capture may be the publisher's TRUNCATED render (NYT sends a ~4.6k-char body and truncates the DOM to ~2.2k client-side — under `PaywallDetector.shortBodyThreshold`, so the lock still counts). Rules: a candidate must be readable AND no shorter than the capture (never trade down to a shorter "readable" crawler page); the silent chain gets the shorter `BypassPlan.trustedCaptureSilentDeadlineSeconds = 8` budget, since the user is already reading something; whatever happens, the capture comes back rather than parking the item. A rule-free host is NO LONGER short-circuited to the capture — the old "nothing the app can do that the browser couldn't" assumption is false for a body the SERVER truncated, which no on-page unlocking can restore but a pre-paywall archive capture can. This is what makes a Safari-side unlock failure self-healing instead of silently truncating the in-app article. Tests: `ArticleResolverTests.testTrustedCapture*`.

**A paywall is a property of the site at a MOMENT, not of the article (`.waybackPrePaywall`).** Newest-first is the wrong end of the capture history for an article the publisher metered years after publishing it. The Paris Review put its interview archive online free and walled it later, so every recent Wayback capture of a 1969 interview carries the same truncated preview the live page serves, while the 2010–2016 captures hold the whole ~50k-character piece. `.waybackPrePaywall` takes the OLDEST non-trivial 200 capture and is ranked AFTER `.waybackRaw` — newest is right for an article walled from publication, where the oldest capture is just an older wall, and the ranking costs nothing because the readability gate (now including `TruncationGateDetector`) discards whichever capture still carries the wall. **It is only SCHEDULED when that era could exist.** A story published this week was walled the day it went out, so its oldest capture is the identical wall and the lookup provably cannot help: `BypassStrategySelector` reads the page's own `article:published_time` / schema.org `datePublished` / `<time datetime>` (`PublicationDate`, zero network, no per-host knowledge) and omits the strategy when the page dates itself inside `ArticleFetcher.prePaywallCaptureMinimumAge` (180 days). An UNDATED page keeps it — absence of a date is not evidence of youth — and so does a page that never arrived at all (WSJ's 401 leaves no markup to date), where `ArticleFetcher.captureCouldPredateAWall` applies the same age test to the resolved capture timestamp as a backstop. That is what stops a save of today's paywalled news from paying for yesterday's long shot. This is the ONLY technique that can beat a server-side truncation: the rest of the body was never sent, so nothing done to the live page — crawler UA, referer, trailing dot, script blocking, `.directUnlock` — can recover it (verified against this page: a Googlebot UA gets a Cloudflare block, a Google referer gets the identical truncation). Tests: `WaybackCDXTests`, `PublicationDateTests`, `ArticleResolverTests.testPrePaywallCaptureBeatsATruncatedPreview`.

**A wall that REDIRECTS instead of gating: the `?amp` unlock (`AMPQueryBypass`).** News
Corp Australia (`theaustralian.com.au` + 13 sibling mastheads) doesn't serve a teaser
at the article URL — it 302s the request onto `…/subscribe/news/1/?dest=<article>`
(see `claudedocs/url-pipeline.md`, incl. the `FetchError.subscribeRedirect` guard that
stops the subscription pitch from being saved as the body). That leaves **every other
strategy with nothing to work on**: no body to un-clamp, no `rel=amphtml` to discover
(`.amp` reads that off the article page), no JSON-LD `articleBody`. But the same URL
with a bare **`?amp`** flag is NOT redirected, and the AMP document carries the whole
story server-rendered in `<section subscriptions-section="content">` blocks that only
`amp-subscriptions-*.js` hides — client-side, after load — so a URLSession fetch gets
the complete article. `.ampQuery` (silent) therefore LEADS the plan on those hosts:
one request, no browser, no CAPTCHA. Verified live on the reported article (direct read
= the pitch; `?amp` = ~4.4k characters of body).

`AMPQueryBypass.extractableHTML` is **load-bearing, not cosmetic**: AMP ships the pitch
in the same document as the story, and its "Already a subscriber? Log in" copy is a
`PaywallDetector.gateMarkers` phrase — which fires at ANY body length — so without
stripping the machine-labeled gate (`[subscriptions-section]` ≠ `content` removed, the
attribute dropped from the content blocks) the extractor would reject a document that
holds the complete article. The browser tier already did the same thing in JS for this
family (`site_cleanup_scripts.json`: the `/subscribe/` hop + the AMP unhide), and the
Safari extension now does too (`claudedocs/safari-extension.md`). Tests:
`AMPQueryBypassTests`, `ArticleResolverTests.testSubscribeRedirect*`.

Pieces (all in `ReaderKit/`):
- `BypassPlan` (`BypassPlan.swift`) — ONE typed `{ silent: [SilentStrategy], webPreStages: [WebStrategy], allowsArchiveToday: Bool }` built by a single factory `make(for:directHTML:)` that splits `BypassStrategySelector`'s ordered list into the typed legs. Both the resolver (silent) and the archive reader (web) consume it, so they can no longer derive divergent orderings (the former double-compute). `SilentStrategy`/`WebStrategy` make the silent/web split unrepresentable (no more "skip the non-silent cases" filter). Trailing-dot is the first silent strategy and `benefitsFromJSRetry == false`, so the factory NEVER repeats it as a ~9s WKWebView pre-stage (the NYT slowness). Tests: `BypassPlanTests`.
- `BypassURLs` (`BypassPlan.swift`) — the ONE strategy→URL mapper (`requestURL(for:article:)` silent, `loadURL(for:article:)` web), replacing the duplicated `switch strategy → URL` in `BypassRunner.run` + `webPreStageURLs`.
- `BypassStrategy` (`BypassStrategy.swift`) — the technique enum. Cases: `.jsonLDBody`, `.userAgent(CrawlerAgent)`, `.referer(RefererOrigin)`, `.trailingDotHost`, `.freshSession`, `.amp`, `.ampQuery` (the `?amp` variant, derived from the article URL alone — see the News Corp AU section above), `.waybackRaw`, `.waybackPrePaywall`, `.jinaReader`, `.ladderProxy(LadderProxy)`, `.thirdPartyWeb(ThirdPartyWebService)`, `.archiveToday`. `runsSilently` is false only for `.thirdPartyWeb` + `.archiveToday` (WKWebView-only). `CrawlerAgent` (googlebotDesktop/Mobile + Googlebot XFF `66.249.66.1`; bingbot, no XFF), `RefererOrigin` (google/facebook/twitter), `LadderProxy.oneFt` (silent server-render proxy), `ThirdPartyWebService` (.smry/.removePaywalls/.removePaywall) carry the verified service URL builders.
- `BypassRuleTable` (`BypassRuleTable.swift`) — static per-host literal (`rule(for:)`, apex+subdomain+trailing-dot match). Seeds ~21 hosts (WSJ/FT/NYT/Economist/Bloomberg/…); every rule ends in `.archiveToday`.
- `BypassStrategySelector.strategies(for:directHTML:)` (`BypassStrategySelector.swift`) — PURE. `[]` when `BypassGate.decision(for:html:extracted:nil)` blocks a bypass (product/platform/readable/not-paywalled). A supported site rule always uses its direct-unlock pre-stage before archive.today; other eligible pages use archive.today (NYT retains its trailing-dot pre-stage). There is no user gate for on-device paywall unlocking.
  - **OFF (default)** → `[.archiveToday]` (+ `.trailingDotHost` first for NYT-family). A detected paywall goes STRAIGHT to the archive reader — the long-standing behavior, no silent fetches, no pre-archive hang.
  - **ON** → a **first-party silent chain** (`firstPartySilent`) then the WKWebView **`.directUnlock`** stage, then archive.today: `[.jsonLDBody, .userAgent(.googlebotDesktop), .userAgent(.googlebotMobile), .freshSession, .amp, .waybackRaw, .directUnlock]` (+ `.trailingDotHost` for NYT) + `.archiveToday`. ON also lets a **rule-listed paywall host** (`PaywallUnlockRules.isKnownPaywallHost`) enter the unlock flow even when the gate found no generic evidence — but ONLY overriding the `.notPaywalled` "no evidence" block, never a readable article / product page / platform link. The silent reads run over URLSession **from the user's own device IP**, which is the point for hard paywalls (esp. **WSJ**): WSJ/Reuters/etc. block the datacenter IPs archive.today and Wayback crawl from (verified: WSJ + Reuters 401 a datacenter IP regardless of UA; and archive.is returns `-32602 cannot archive` on new WSJ articles), so the archiver only gets a teaser/CAPTCHA loop, whereas a Googlebot-UA + cookieless read from the reader's residential/cellular IP *may* get the full article (WSJ serves full text to Googlebot for SEO; UA-based — same as the reference paywall rules' `wsj.com → useragent: "googlebot"` + cleared cookies). **Default OFF because the silent chain adds up to ~20s of pre-archive latency and, in practice, WSJ also appears to reject Googlebot from arbitrary IPs — so the chain often doesn't help and the wait was a regression.** The Googlebot read is cookieless (`ArticleFetcher.fetchHTML(from:userAgent:xForwardedFor:)` uses an ephemeral session). Third-party reader/proxy services (`.jinaReader`/`.ladderProxy`/third-party pages) are deliberately NOT used — only first-party reads + the public archives.
- `BypassRunner` (`BypassRunner.swift`, protocol `BypassRunning` + mock) — maps each SILENT strategy to a `HTMLFetching` call (URLs via `BypassURLs`) + the shared `ArticleExtraction.fetchAndExtract`, returning `ExtractedArticle?`; WKWebView-only strategies return nil. `.jsonLDBody` is zero-network (`extractFromJSONLD` forces the JSON-LD `articleBody` layer even on a paywalled-looking DOM).
- `HTMLFetching` protocol on `ArticleFetcher` (+ `MockArticleFetcher` in tests) so the resolver/runner are network-free in unit tests. Silent fetches: crawler UA/XFF, spoofed referer, ephemeral no-cookie session, `fetchWaybackRawHTML` (CDX newest-200 **raced against the Availability API** → raw `…/web/<ts>id_/<url>` replay, or IA's rewritten replay when Availability wins; pure parser `newestSnapshotTimestamp(fromCDXJSON:)`), `fetchWaybackPrePaywallHTML` (the OTHER end of the same history — CDX `limit=5` oldest-200 → the same raw replay, on the shorter speculative index budget and skipped outright when the capture is too recent to predate a wall; pure parsers `oldestSnapshotTimestamp(fromCDXJSON:)` + `captureCouldPredateAWall`; throws rather than falling back to the Availability API, which only answers "closest to now" and is what the newest attempt already tried), `fetchJinaReader`. (`fetchArchivedHTML` was removed — see above.)

Third-party service request formats (owner-required fallbacks): `1ft.io/<raw url>` (silent), `smry.ai/<raw url>` + `removepaywalls.com/<raw url>` (WKWebView, path prefix) + `www.removepaywall.com/search?url=<encoded>` (WKWebView, query param), Wayback raw (silent), archive.today (WKWebView terminal). All fail gracefully — a dead one falls through via the readability gate. Tests: `BypassStrategySelectorTests`, `BypassRuleTableTests`, `BypassRunnerTests`, `BypassServiceURLTests`, `WaybackCDXTests`, `JSONLDExtractorTests`, `TrailingDotBypassTests`, `ArchiveWebPreStageTests` (fixtures under `LunaTests/Fixtures/`).

`resolution(...)` counts an `ExtractedArticle` readable via the shared `ArticleExtraction.isReadableArticle` predicate (the only place that decision lives). Outcome → ingestor state:
- `.readable` → `.ready`.
- `.paywalled(title)` → `.needsCaptcha`.
- `.unreadable` → `.failed` **only for ordinary sites**. For a **hard-paywall host** (`ArticleFetcher.isHardPaywallHost` — WSJ/FT/NYT/Economist/Bloomberg/…) **or an archive.today URL** (`isArchiveTodayURL`), it parks as `.needsCaptcha` with a humanized placeholder title (`articleTitleGuess`, slug-derived, archive URLs unwrapped to the original via `originalURL(fromArchiveURL:)`). So a blocked WSJ/FT save offers the archive path instead of dropping into failed imports.

**The card wears a lock while it waits.** A `.needsCaptcha` article has no body, so its
card used to be a bare centred "Locked — tap to unlock", which read as a card that had
FAILED rather than one waiting on a tap. It now carries
`LockedCardOverlayView` (LunaDesignSystem): a large `lock.fill` in
`GlassStyle.lunaBrandAccent` over a wash of the same colour, both under 1.0 alpha — the
card is dimmed and watermarked, not replaced — with the caption beneath and the title
header still crowning it. The overlay sets `isUserInteractionEnabled = false`, which is
the load-bearing part: it covers the whole card, and the card's own **tap** (→
`unlockCurrentCardIfNeeded` → the archive reader) and **long-press** (→ Archive /
Delete, `cardContextMenu` — a locked save is not a failed save, so it keeps both verbs)
must pass straight through. An overlay that swallowed them would look perfectly right
and break both gestures; `LockedCardOverlayViewTests` hit-tests for exactly that.
The deck's **Share pill stays visible** too — `updateReaderChrome` normally hides it
along with the rest of the chrome when there's no reader, but a locked card still has a
URL and sharing it is the one thing that works before the unlock. It goes straight to
the SYSTEM sheet (`SendToFriendSheet.shareLink`), not `AppReaderShareProvider`'s ladder,
because a locked save has no extracted text, so no format can be exported — the same reasoning as the
failed card's share (`claudedocs/failed-saves.md`).

Opening a `.needsCaptcha` item (`ArticleCardsViewController.presentArchiveReader`) presents the WKWebView **`ArchiveWebReaderViewController`** (NOT SFSafariViewController — the host app can't read SFSafari's DOM, so it could never extract). It loads the exact snapshot when the saved URL is already archive.today, else `archive.is/newest/<canonical>`; persistent cookie store + device-matched Safari UA so a solved Cloudflare `cf_clearance` sticks. On `didFinish` with innerText > 1500 (and not the challenge page) it reads its own `outerHTML`, extracts, `saveContent`, and fires `onExtracted` → the host dismisses and reopens the now-`.ready` item in the native reader. An **"Open in Safari"** button (`onOpenInBrowser` → `SFSafariViewController`) is the escape hatch when the embedded view can't clear the gate. Tests: `ArticleFetcherTests` (host detection, archive-URL unwrap, title guess).

**Ordered WKWebView pre-stage list.** Before any archive.today navigation, the reader walks an ordered list of WKWebView pre-stage URLs — `ArchiveWebReaderViewController.webPreStageURLs(for:)` (pure, static, tested by `ArchiveWebPreStageTests`): the `BypassPlan.make(for:directHTML:nil).webPreStages` leg mapped to loadable URLs via `BypassURLs.loadURL`. The plan only includes a `.trailingDotHost` pre-stage when it did NOT run silently (it doesn't `benefitsFromJSRetry` — a pure origin trick returns the same wall in a browser), so a host like NYT whose rule leads with a silent trailing-dot goes silent-trailing-dot → (fail) → third-party pages → archive.today, skipping the ~9s redundant trailing-dot pre-stage (the speed fix). `.thirdPartyWeb` → smry.ai/removepaywall(s).com page URLs. archive.today (the terminal flow) is excluded; an archive.today URL yields no pre-stages. `checkStage` routes to `checkDirectBypassStage` while `isAttemptingDirectBypass`: poll the page's text length and `extractAndSave` (baseURL stays the canonical article URL); a readable extraction from ANY pre-stage finishes via the normal `onExtracted` path (no archive.today at all). If the current pre-stage doesn't yield a readable article within `bypassPollLimit` (≈9s), `advanceToNextPreStage` loads the next one; when the list is exhausted, `fallBackToArchiveFromBypass` switches to the standard archive.today flow (`loadArchive` + `resolveSnapshotInParallel`). The trailing-dot transform is the former NYT pre-stage, now emitted by the selector for any host with a `.trailingDotHost` strategy (NYT/WaPo/LAT/… per the rule table + the generic metered branch). Unit-tested (`TrailingDotBypassTests`, `ArchiveWebPreStageTests`).

**Pre-stage readiness needs PROSE, not a container.** `checkDirectBypassStage`'s probe
(`ArchiveWebReaderViewController.directBypassStageProbeJavaScript`, public so
`ArchiveDirectBypassReadinessTests` can evaluate it against fixture pages) used to
call the page ready as soon as `querySelector('article, …')` matched anything. WSJ
wraps TEASER CARDS in their own `<article>`, so on a page whose real body hadn't
hydrated the first match was a headline and a line of standfirst — the flow declared
success and the whole-document extraction saved teaser prose plus page furniture as
the article, clearing the readable gate on furniture alone. There was no retry and no
archive fallback, because nothing had failed. The probe now scans EVERY match and
requires one holding at least `ArticleContent.readableBodyThreshold` characters, so it
can never call a page ready that extraction would then reject; a thin teaser keeps
polling and falls through to the next pre-stage / archive.today. The archive.today
branch of `extractAndSave` picks the RICHEST matching container for the same reason
(it still isolates a node, so archive.today's own chrome stays walled off).

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

`ReaderSettings`: fontScale (S/M/L/XL segmented) and font (`ReaderFont` — System/New York/Charter/STIX Two, all iOS-resident, the named families openly licensed; legacy `useSerifFont` maps to New York/System until the user picks). The renderer reads font settings at render time and multiplies fontScale by the CLAMPED system Dynamic Type scale (`ReaderSettings.systemTypeScale`, 0.85…1.6, so accessibility sizes are honored without breaking the card column). Reading time and progress remain visible in article rows but are no longer user settings. The Reader settings page also owns link preload depth and Wi-Fi-only controls.

## Read-aloud (Luna/Reader/SpeechController.swift)

AVSpeechSynthesizer, block-per-utterance. Scroll reader: floating glass speaker button → footer controls (paragraph skip ±, play/pause, rate cycle 0.8/1/1.2/1.5×); current word highlighted and auto-centered (follow disabled when the user drags, re-enabled on control taps); resume position (`lastSpokenWordIndex`) persisted and highlighted on open until first user scroll. Background playback: `UIBackgroundModes audio`, AVAudioSession `.playback/.spokenAudio`, MPRemoteCommandCenter + NowPlaying. RSVP: speaker toggle speaks whole SENTENCES (natural prosody, normal pace) and flashes each word via `willSpeakRangeOfSpeechString` offsets; WPM ignored. No newer synthesis API exists in the iOS 26/27 SDKs (AVSpeechSynthesizer remains the system API). Word indices shared via `Luna/Reader/WordMap.swift` (built from `RenderedArticle.blockTextRanges`; same tokenization as RSVPEngine).

### TTS engines (`ReaderKit/SpeechEngine.swift` + Settings → Audio)

Voice is abstracted behind `SpeechEngine` (protocol) with `VoiceEngineKind { basic, appleEnhanced }`. There are NO downloadable/neural voices — Luna only uses OS-resident Apple voices (the former Piper/Kokoro Hugging-Face download stack and `VoiceModelRegistry`/`VoiceModelDownloadManager`/`NeuralSpeechEngines` were removed). Both engines drive the SAME `AVSpeechSynthesizer` by CONFIGURING the utterance (voice + rate) via `configure(_:rate:)`, so `willSpeakRangeOfSpeechString` keeps firing and word highlighting works identically. `SpeechController` and RSVP resolve the engine per play session via `SpeechEngineFactory.resolveSelected()`, which is simply "the enhanced Apple voice if one is installed, otherwise basic" — identical in the app and its extensions. Engines:
- **basic** (`BasicSpeechEngine`): system default voice. Always available. The fallback when no enhanced voice is installed.
- **appleEnhanced** (`AppleEnhancedEngine`): best installed enhanced/premium voice for the locale (premium > enhanced). "Availability" = such a voice is installed; apps CANNOT download Apple voices — the user installs them in iOS Settings → Accessibility → Spoken Content → Voices.

`VoiceModelStore` (App Group `group.com.hsanabria.luna`) holds only `hasSeenVoicePrompt` and the convenience `isAppleEnhancedInstalled` check (no engine selection, no on-disk models). The Voice section is inline on `AudioSettingsScreen`: it shows whether an enhanced voice is installed and an "Install Enhanced Voices" row that deep-links to iOS Settings via `VoiceInstallLink.open()` (tries `App-Prefs:root=ACCESSIBILITY` → `App-Prefs:` → `openSettingsURLString`). **First-run prompt**: the first time read-aloud starts in the app, `VoiceFirstRunPrompt.showIfNeeded` shows a one-time non-blocking "Better Voices Available" alert (playback proceeds with the standard voice) gated by `hasSeenVoicePrompt`; "Open Settings" now opens the Audio page.

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

**That gate is opened by ONE appearance callback, so a reparented deck must be
given it back.** `CardCarouselViewController` promotes its centered slot from
`viewDidAppear` (and from `reloadData` when already visible) — nothing retries, by
design: re-running `cardDidBecomeCentered()` would restart a media card's
playback. Onboarding, though, mounts the production root as a HIDDEN CHILD long
before the handoff (`mountCompletedRootIfNeeded`, so the deck can be laid out and
snapshotted for the app-switcher hop), which leaves UIKit with an appearance
transition in flight — `viewWillAppear` delivered, `viewDidAppear` not. Reparenting
mid-transition unbalances that bookkeeping and the tree settles in the
**disappeared** state while its views are on screen: `viewDidAppear` never arrives
at all, `isViewVisible` stays false, the centered card is never promoted, and EVERY
card sits on its 700-character Phase-1 prefix until the app is force-quit (which is
exactly how the bug read from the outside — "saves are dropping most of their
content"). `AppOnboardingCompletionTransition.install` therefore drives the
transition itself (`beginAppearanceTransition(true)` / `endAppearanceTransition()`)
after installing the root, but only when the root actually WAS reparented — the
freshly-built root of the external-save path gets its appearance from UIKit
normally. Tests: `OnboardingHandoffFullContentTests` (cold-launch baseline, the
fresh-root handoff, and the preloaded-root handoff that regressed).
