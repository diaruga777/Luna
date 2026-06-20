# Audit 05 — Social / Platform / Media URL recognition

Scope: recognizing a URL as a social/video/audio platform link and producing a
no-article item with the right metadata + rendering — NEVER routing it through
article text extraction. Owner-reported symptom: YouTube links sometimes get
text-extracted. Recognition must be deterministic and identical on every surface.

Files audited (paths absolute under `/Users/hsp/Desktop/monorepo/production/ios-client/clip`):
`ReaderKit/PlatformClassifier.swift`, `ReaderKit/NonTextualContent.swift`,
`ReaderKit/YouTubeURL.swift`, `ReaderKit/ContentPlatform.swift`,
`ReaderKit/MediaItemKey.swift`, `ReaderKit/ReadingListItem.swift`,
`ReaderKit/ArticleIngestDecider.swift`, `Clip/Platforms/PlatformRegistry.swift`,
`Clip/Platforms/PlatformModule.swift`, all `Clip/Platforms/**` modules,
`Clip/ReadingList/ReadingListIngestor.swift`, `Clip/ReadingList/PasteboardSuggester.swift`,
`ShareKit/ShareViewController.swift`, `ShareKit/ShareReaderViewController.swift`,
`ShareKit/SharedReadingListAppender.swift`, `Clip/Social/SocialMessageCenter.swift`,
`ClipSafari/*`, the `Clip/Intents/*` save/find intents, and the relevant `ClipTests/*`.

---

## 1. Current-state map

### The recognizer that actually runs: `PlatformClassifier` (ReaderKit)

`PlatformClassifier.classify(_ urlString) -> PlatformClassification?` is the de-facto
single authority. It lives in ReaderKit so the app AND both extensions can call it.
It is one big inline `if/else` over `url.host` (lowercased) + path segments, hardcoding
the host/path patterns for **every** platform:

- YouTube — delegates to `YouTubeURL.videoID` (so all YT hosts handled there).
- Bluesky — `bsky.app` + `/profile/<author>/post/<rkey>`.
- X — `x.com`/`twitter.com` (+ subdomains via `matches`) + `/status|statuses/<id>` (numeric id only).
- TikTok — `*.tiktok.com` + `/video/<numeric id>` (short `vm./vt.` recognized, id nil).
- Reddit — `*.reddit.com` + `/comments/<id>`, or `redd.it/<id>`.
- Instagram — `*.instagram.com` **or `instagr.am`** + `/(p|reel|reels|tv)/<shortcode>`.
- Facebook — `*.facebook.com`, `fb.watch`, `fb.com` + `?v=` / `/reel|/videos/<id>`.
- Spotify — `*.spotify.com` + `/track|album|artist` → `.music`, `/episode|show` → `.podcast`, `sourceService=.spotify`.
- Apple — `music.apple.com` → `.music`, `podcasts.apple.com` → `.podcast`, id = `?i=` or last segment, `sourceService=.apple`.

Returns `PlatformClassification(platform, itemID?, sourceService?)`. Host helper
`matches(host, domains...)` does exact-or-suffix subdomain matching. Pure, no network.

### `YouTubeURL` (ReaderKit) — the one extracted recognizer

`YouTubeURL` is a self-contained enum: a `youtubeHosts` set
(`youtube.com/www/m/music/-nocookie` + `youtu.be`), `videoID(from:)` (handles
`/watch?v=`, `/shorts|embed|live|v/<id>`, `youtu.be/<id>`), `validated()` (11-char
id check), plus `watchURLString`, `appURL`, `thumbnailURL`. `PlatformClassifier`
calls `YouTubeURL.videoID` first — so YT is the only platform whose recognition is
genuinely shared/extracted rather than re-implemented inline.

### `NonTextualContent` (ReaderKit) — a thin re-wrapper of the classifier

`NonTextualContent.detect(urlString:)` calls `PlatformClassifier.classify` and maps
it to an enum: `.youTube(videoID:)` or `.platform(ContentPlatform, itemID:)`. It also
owns YouTube-only embed derivations (`embedURL` = `/embed/<id>` + playback params,
`embedReferer`, `staticPreviewImageURL` = `img.youtube.com/.../hqdefault.jpg`). For
`.platform` cases `embedURL`/`staticPreviewImageURL` are nil. This is what the share
extension uses to decide "non-textual vs article."

### `PlatformRegistry` + `PlatformModule` — a SECOND recognizer surface that is dead for recognition

`PlatformModule` protocol declares `classify(_:) -> PlatformMatch?` plus rendering
hooks (`subtitle`, `appDeepLink`, `embed`, `glyphSymbolName`, optional `metadataFetcher`).
There are 9 concrete modules (`YouTubePlatform`, `XPlatform`, `BlueskyPlatform`,
`RedditPlatform`, `TikTokPlatform`, `InstagramPlatform`, `FacebookPlatform`,
`MusicPlatform`, `PodcastPlatform`), each with a `classify` body that re-derives the
same host/path match via a per-platform `Link` parser (`XLink`, `BlueskyLink`,
`RedditLink`, `TikTokLink`, `InstagramLink`, `FacebookLink`, `MediaLink`).

**But `PlatformRegistry.detect` does NOT call any module's `classify`** — it calls
`PlatformClassifier.classify` and wraps the result (`PlatformRegistry.swift:35-38`).
`module(for:)` is used only for rendering/metadata dispatch. So every module's
`classify` is **production-dead code** (only `YouTubePlatform.classify` and the
modules' `classify` are exercised by unit tests — `PlatformRegistryTests`,
`PlatformParsersTests` — never on a real save). The per-platform `Link` parsers ARE
live, but only via the modules' `subtitle`/`metadataFetcher`, not for classification.

Net: there are **three** recognition expressions of the same rules —
`PlatformClassifier` (live), the 9 module `classify` + their `Link` parsers (dead for
classification, live for rendering), and `YouTubeURL` (shared, called by both).

### Data model

`ReadingListItem` (ReaderKit): platform fields are optional + `decodeIfPresent`
(`platform`, `platformItemID`, `mediaCreatorName`, `mediaItemTitle`,
`mediaSourceService`, legacy `youtubeVideoID`/`channelName`). Computed
`contentPlatform` (falls back to `.youtube` for legacy items with a `youtubeVideoID`),
`isPlatformItem`, `isURLlessMedia`, `isYouTubeVideo`. `ContentPlatform` enum +
`MusicProvider`. `MediaItemKey` builds the synthetic `clickmusic://`/`clickpodcast://`
key for URL-less media items.

### Where recognition is invoked, per surface

| Surface | File:line | Recognizer used | Order vs article extractor | OK? |
|---|---|---|---|---|
| Main app ingest | `ReadingListIngestor.swift:101,110` | `YouTubeURL.videoID` then `PlatformRegistry.shared.detect` | both BEFORE `ArticleIngestDecider.decide` (line 151) | ✅ |
| Paste suggester | `PasteboardSuggester.swift:72,85` | `YouTubeURL.videoID` then `PlatformRegistry.shared.detect`; dedup uses `PlatformClassifier.classify` (112) | both BEFORE article extract (95) | ✅ |
| Share ext (zero-UI append) | `SharedReadingListAppender.swift:18` | none — writes a raw `pending` JSON dict | classification deferred to main-app ingest | ✅ (deferred) |
| Share ext (no reader mode) | `ShareViewController.swift:279` | `NonTextualContent.detect` | guards before `ingestArticleThenComplete` | ✅ |
| Action ext (reader mode) | `ShareViewController.swift:288` | `NonTextualContent.detect` | guards: platform → `presentSavedNonTextual`, else `presentReader` | ✅ |
| **Action ext inline reader** | **`ShareReaderViewController.swift:73-104`** | **NONE** — calls `ArticleIngestDecider.decide(url:)` directly | **no platform/YT guard at all** | ❌ |
| Intents (SaveLink / platform / find / Safari page) | → `ReadingListIngestor.handleSavePress` → `ingest` | shared ingest path | ✅ |
| Safari extension | `ClipSafari/*` records URL only; shortcut → save intent → `ingest` | shared ingest path | ✅ |
| Friend receive (CloudKit) | `SocialMessageCenter.swift:54,~344` | `startIngest` → `ReadingListIngestor.shared.ingest` | shared ingest path | ✅ |

### The single "shared decider" is platform-blind

`ArticleIngestDecider.decide` (ReaderKit) documents itself as "the SINGLE shared
decision routine used identically by the main-app ingestor AND both share-sheet
extensions." Its pipeline is: (1) product detection → (2) article resolution +
bypass → (3) `.article`/`.needsArchive`/`.failed`. **It contains no
platform/YouTube/non-textual branch** (grep for `NonTextual|PlatformClassifier|
PlatformRegistry|youtube` inside it returns nothing). Platform recognition is bolted
on by each caller *before* invoking the decider — and the action-extension reader
forgets to do so.

---

## 2. Problems

1. **The "single decider" doesn't decide the social/video/audio case.** Platform
   recognition is layered *outside* `ArticleIngestDecider` (ingestor: two `if`s
   before the call; share VC: `NonTextualContent.detect` before the call). The
   decider's own contract claims to be the single point of truth but it only covers
   article/price/paywall. Any caller that hits the decider without first guarding for
   platforms will text-extract a video/post. This is the structural root of the
   YouTube bug class.

2. **Confirmed divergent surface: `ShareReaderViewController.ingestAndPresent`
   (`:73-104`)** calls `ArticleIngestDecider.decide(url:)` with no `NonTextualContent`
   / platform guard. A YouTube/social URL reaching this VC is run through article
   extraction and lands as `.article`/`.failed` ("Couldn't Load") instead of a video.
   In the current share flow this VC is reached only via `ShareViewController.routeSavedOrReader`,
   which *does* guard (`:288`) — so the bug is latent there today — but it is *also*
   constructed directly by `UITestScreen.swift:121`, and nothing in the type system
   stops a future caller from presenting the reader on an unclassified URL. The guard
   lives in the caller, not in the decider, so it is one forgotten call site away
   from shipping. (This matches the documented prior regression in the VC's own
   comment about previously calling `ArticleResolver.resolve` directly.)

3. **Three overlapping recognizers; one is dead.** `PlatformClassifier` reimplements,
   inline, the exact host/path logic that each `PlatformModule.classify` + its `Link`
   parser already expresses. `detect` ignores the modules. So the rules are written
   twice (classifier + module/Link) and can drift — and already have:
   `PlatformClassifier` matches `instagr.am`, but `InstagramLink.isInstagram` does
   not; the classifier matches `x.com`+subdomains via `matches`, while `XLink.hosts`
   is a fixed set (`mobile.twitter.com` etc.). Two sources of truth for the same
   recognition is exactly what the vision forbids.

4. **Recognition is tangled with the registry's rendering responsibilities.**
   `PlatformModule` mixes recognition (`classify`) with rendering (`subtitle`,
   `embed`, `appDeepLink`) and fetching (`metadataFetcher`). Because `classify` is
   dead, the registry is really a *rendering/fetch* dispatch table wearing a
   recognizer's clothes — confusing, and it invites someone to "fix" recognition by
   wiring `detect` to the modules, re-duplicating the classifier.

5. **Non-extensible matching.** Adding/adjusting a platform means editing the inline
   `if`-ladder in `PlatformClassifier` *and* (for rendering) adding a module *and*
   (for consistency) a `Link` parser. Hosts/paths are scattered across literals and
   `Set`s in 10+ files rather than one declarative table. There is no single list to
   lengthen ("the longer the known-URL list, the better").

6. **`NonTextualContent` vs `PlatformRegistry` redundancy.** Both wrap
   `PlatformClassifier`. `NonTextualContent` exists because extensions can't link the
   app's `PlatformRegistry`/modules; it returns an enum + YT embed helpers, while
   `PlatformRegistry.detect` returns `PlatformMatch`. Two wrapper APIs over one
   recognizer, used inconsistently (extensions use `NonTextualContent`, app surfaces
   use `PlatformRegistry`). They can't disagree today (same backing call) but they're
   parallel ladders that must be kept in lockstep by hand.

---

## 3. Proposed simplified design

### One extensible platform table

Replace the inline `if`-ladder and the 9 dead `classify` bodies with a single
declarative table of entries. Each entry owns its host list, an id-extraction
closure, and its `ContentPlatform`/`MusicProvider`. The recognizer iterates the
table; adding a platform = appending one entry (and, separately, a renderer).

```swift
/// A pure URL → platform rule. Recognition only — no fetching, no rendering.
struct PlatformRule {
    let platform: ContentPlatform
    let service: MusicProvider?          // music/podcast only
    /// Hosts matched exactly OR as a subdomain (e.g. "tiktok.com" matches "vm.tiktok.com").
    let hosts: [String]
    /// Extracts the item id from already-parsed parts; nil id is allowed
    /// (short links / opaque pages still classify as the platform).
    let itemID: (_ host: String, _ segments: [String], _ query: [URLQueryItem]) -> String?
}
```

### One shared recognizer feeding a typed kind

`recognize(url)` is the ONE entry point; it is the only thing that reads the table.
A small `PlatformKind` (`.video/.social/.audio`) lets the classifier route without
caring which platform:

```swift
enum PlatformRecognizer {
    static let rules: [PlatformRule] = [
        .youTube,                                  // wraps YouTubeURL.videoID
        .x, .bluesky, .reddit, .tiktok,
        .instagram, .facebook,
        .spotify, .appleMusic, .applePodcasts,
    ]

    /// The single deterministic recognizer used IDENTICALLY on every surface.
    /// Pure: no network, no UIKit — compiles in extensions.
    static func recognize(_ urlString: String) -> RecognizedPlatform? { … }
}

struct RecognizedPlatform: Equatable {
    let platform: ContentPlatform
    let itemID: String?
    let service: MusicProvider?
    var kind: PlatformKind { platform.kind }   // .video / .social / .audio
}
```

`NonTextualContent` and `PlatformRegistry.detect` both collapse to thin adapters over
`recognize` (or `NonTextualContent` becomes the canonical return type and
`PlatformRegistry` keeps only `module(for:)` for rendering). The dead module
`classify` methods are deleted from the protocol; modules keep only rendering +
`metadataFetcher`. `Link` parsers either back the table's `itemID` closures (so the
rule and the parser share one implementation) or are removed where the table closure
subsumes them.

### Recognition gated INSIDE the shared decider

Move the platform check to the top of the one routine every surface already funnels
through, so no caller can forget it:

```swift
enum ArticleIngestDecision {
    case platform(RecognizedPlatform)   // NEW — short-circuits before any fetch
    case priceTracker(ProductInfo, html: String?)
    case article(ArticleContent, html: String?)
    case needsArchive(title: String?)
    case failed
}

// ArticleIngestDecider.decide, step 0 (before product detection / any network):
if let recognized = PlatformRecognizer.recognize(url.absoluteString) {
    return .platform(recognized)        // NEVER text-extract a platform URL
}
```

Then `ShareReaderViewController`, `ShareViewController`, and `ReadingListIngestor`
all get the `.platform` case for free and present it (saved-non-textual / mark
`.ready`) instead of text-extracting — the action-extension gap (Problem 2) closes
by construction, and the ingestor's two pre-call `if`s (`:101,110`) collapse into the
decider. Metadata fetch + thumbnail stay where they are: a *separate*, best-effort,
async step keyed off `recognized.platform` (the module's `metadataFetcher`), never
required for recognition or for the `.ready` transition.

Result: recognition is **one table**, **one `recognize`**, **separate from fetch**,
**impossible to bypass** (it's the first branch of the shared decider), and adding a
platform is one `PlatformRule` + one renderer.

---

## 4. Testability

Recognition is pure (`String -> RecognizedPlatform?`), so the whole table is tested
by a single data-driven test sweeping real example URLs — positives (host variants,
path shapes, short links) and negatives (articles, junk). This is where the
"YouTube wrongly text-extracted" bug should be permanently pinned: one table, asserted
identical to what every surface sees (because every surface calls the same `recognize`).

Concrete cases to assert (`expected platform`, and `itemID` where deterministic):

- **YouTube** (`.video`): `https://www.youtube.com/watch?v=dQw4w9WgXcQ` →id `dQw4w9WgXcQ`;
  `https://youtu.be/dQw4w9WgXcQ`; `https://m.youtube.com/watch?v=…`;
  `https://music.youtube.com/watch?v=…`; `https://www.youtube.com/shorts/<id>`;
  `https://www.youtube.com/live/<id>`; `https://www.youtube-nocookie.com/embed/<id>`;
  `https://youtu.be/<id>?si=track` (tracking param tolerated); reject
  `https://www.youtube.com/@channel` (no video id → not a video) and
  `https://www.youtube.com/feed/subscriptions`.
- **X** (`.social`): `https://x.com/jack/status/20` →`20`;
  `https://twitter.com/u/status/1234567890123456789`; `https://mobile.twitter.com/u/status/20`;
  `https://x.com/u/statuses/20`; `https://x.com/u/status/20?s=46&t=abc` (id `20`,
  params stripped); platform-but-no-id `https://x.com/jack`; reject
  `https://example.com/u/status/20`.
- **Instagram** (`.social`): `https://www.instagram.com/reel/Cx/` →`Cx`;
  `https://instagram.com/p/AbC/` →`AbC`; `https://instagr.am/p/AbC/`;
  `https://www.instagram.com/tv/Xyz/`; `https://www.instagram.com/reels/Xyz/`;
  platform-but-no-id `https://instagram.com/someuser`.
- **TikTok** (`.video`): `https://www.tiktok.com/@u/video/7212345678901234567` →
  `7212345678901234567`; short `https://vm.tiktok.com/ZMabc/` (id nil, still TikTok);
  `https://vt.tiktok.com/ZSabc/`; `https://m.tiktok.com/v/<id>.html`; reject
  `https://example.com/@u/video/1`.
- **Facebook** (`.video`/`.social`): `https://www.facebook.com/watch/?v=123` →`123`;
  `https://facebook.com/reel/456` →`456`; `https://www.facebook.com/u/videos/789` →`789`;
  short `https://fb.watch/abcdef/` (id nil); `https://fb.com/...`.
- **Reddit** (`.social`): `https://www.reddit.com/r/swift/comments/abc123/title/` →
  `abc123`; `https://old.reddit.com/r/swift/comments/abc123/t/`; `https://redd.it/abc123`
  →`abc123`; reject `https://example.com/r/swift/comments/x/y`.
- **Bluesky** (`.social`): `https://bsky.app/profile/alice.bsky.social/post/3kabc` →
  `3kabc`; `https://bsky.app/profile/did:plc:xyz/post/3kabc`; reject
  `https://bsky.app/profile/alice` (no post).
- **Spotify** (`.audio`): `https://open.spotify.com/track/abc` →music/spotify;
  `https://open.spotify.com/episode/xyz` →podcast/spotify;
  `https://open.spotify.com/album/…`, `/artist/…`, `/show/…`.
- **Apple** (`.audio`): `https://music.apple.com/us/album/x/1?i=2` →music/apple, id `2`;
  `https://podcasts.apple.com/us/podcast/x/id1?i=2` →podcast/apple.
- **Negatives**: `https://en.wikipedia.org/wiki/Swift`, `https://www.nytimes.com/2026/01/01/story.html`,
  `"not a url"`, `mailto:x@y.com`, `clipdoc://<uuid>` → all nil.

Plus a **parity test** asserting `recognize` is what each surface uses: e.g.
`ArticleIngestDecider.decide` returns `.platform` (never `.article`) for every
positive URL above — which directly regresses the action-extension YouTube bug.

Existing tests to fold in / keep: `PlatformClassifierTests` (becomes the table sweep),
`PlatformParsersTests` + `PlatformRegistryTests` (the `Link`/module tests survive only
if the parsers still back the table; otherwise delete the dead-`classify` assertions),
`NonTextualContentTests` (keep the YT embed/preview derivations; drop duplicate
recognition asserts), `MediaPlatformTests`, `YouTubeURLTests`.

---

## Recommended platform-recognition API + table entry

```swift
// ReaderKit — pure, extension-safe. The ONLY place URL→platform rules live.

enum PlatformKind { case video, social, audio }

struct RecognizedPlatform: Equatable {
    let platform: ContentPlatform
    let itemID: String?
    let service: MusicProvider?   // music/podcast only
}

struct PlatformRule {
    let platform: ContentPlatform
    let service: MusicProvider?
    let hosts: [String]   // exact OR subdomain match
    let itemID: (_ host: String, _ segments: [String], _ query: [URLQueryItem]) -> String?
}

enum PlatformRecognizer {
    static let rules: [PlatformRule] = [
        // YouTube reuses the one extracted recognizer — no host list duplicated.
        PlatformRule(platform: .youtube, service: nil,
                     hosts: ["youtube.com", "youtu.be", "youtube-nocookie.com"]) { _, _, _ in nil }
            .overridingID { url in YouTubeURL.videoID(from: url) },

        // Adding a platform = appending ONE entry like this:
        PlatformRule(platform: .tiktok, service: nil, hosts: ["tiktok.com"]) { _, segments, _ in
            guard let i = segments.firstIndex(of: "video"), i + 1 < segments.count else { return nil }
            let id = segments[i + 1]
            return id.allSatisfy(\.isNumber) ? id : nil
        },

        PlatformRule(platform: .music, service: .spotify, hosts: ["spotify.com"]) { _, segments, _ in
            guard segments.first.map({ ["track", "album", "artist"].contains($0) }) == true,
                  segments.count > 1 else { return nil }
            return segments[1]
        },
        // …x, bluesky, reddit, instagram, facebook, applePodcasts, appleMusic…
    ]

    /// The single deterministic recognizer. Used identically by ingest, paste,
    /// share/action extensions, intents, and friend-receive — by being the first
    /// branch of `ArticleIngestDecider.decide`, so NO surface can text-extract a
    /// platform URL.
    static func recognize(_ urlString: String) -> RecognizedPlatform? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else { return nil }
        let segments = Array(url.pathComponents.dropFirst())
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for rule in rules where rule.hosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            // First matching host wins; id may be nil (short link / opaque page still classifies).
            return RecognizedPlatform(platform: rule.platform,
                                      itemID: rule.itemID(host, segments, query),
                                      service: rule.service)
        }
        return nil
    }
}
```
