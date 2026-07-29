# X posts as reader articles

Luna and Luna Reader save a **long-form X post** as a readable article instead of
an opaque social card. Short posts are unaffected: they stay social items exactly
as before. The Downloader and Price Tracker are unaffected entirely.

## Why this needs an API, not extraction

X serves an unauthenticated client a JavaScript login shell — `x.com/<user>/status/<id>`
returns ~215 KB of HTML with **no post text in it**. So the ordinary
fetch → extract → bypass tiers can never read an X post, and no amount of paywall
strategy changes that.

The text comes instead from **fxtwitter** (`api.fxtwitter.com`), the keyless
read-only public mirror the codebase already reads for X metadata
(`XMetadataFetcher`) and X media (`SocialMediaResolver`). This path asks it for the
post's text. Two endpoints, in order:

| Endpoint | Purpose |
| --- | --- |
| `GET /2/thread/<id>` | The **unrolled** self-reply chain — `{status, thread, author}` |
| `GET /status/<id>` | v1 single-post fallback if v2 is unavailable |

`/2/thread` unrolls the whole thread **from any member** (verified against a
mid-thread id), and returns author-only posts already in posting order. There is
therefore no backward `replying_to_status` walk: one call covers both the
single-post and the chained-thread case. A short post costs exactly one request —
the v1 fallback is not retried, because it would return the same post.

## What qualifies

Two tiers, checked in order (`XPostExtractor`):

1. **X Article** — the premium long-form editor (`post.article`). It carries its
   own title and a Draft.js body, so its presence alone establishes long-form and
   the length threshold is **not** applied.
2. **Post text** — one long post, or the poster's own unrolled thread. Accepted
   only when the assembled body reaches **`minimumBodyTextLength` (600
   characters)**.

Declining returns nil, which is the ordinary case and never an error: the pipeline
falls back to `.social` and the save behaves exactly as it did before.

### Why 600 characters, and not X's own long/short flag

X *does* expose a flag, `is_note_tweet`, and deferring to the platform's own
distinction would be preferable to a heuristic. **Measured against live posts, it
does not carry that meaning.** It marks "composed in the note editor", which X now
sets for ordinary posts too — a 280-character one-liner comes back
`is_note_tweet: true`, i.e. the flag is true at the exact length an ordinary post
caps out at. It cannot separate an essay from a quip, so a length gate on the
assembled body is the honest rule. The flag is still decoded (it is genuine
platform signal) but is never read as a decision.

600 sits deliberately far above X's 280-character ordinary-post cap, so **no
single normal post can clear it however it was composed**, while a genuine
long-form post or a short chained thread does. Image blocks contribute no text, so
the gate measures prose only.

This is distinct from `ArticleContent.readableBodyThreshold` (1200), which
calibrates "did HTML extraction get a real article or a paywall stub" — a
different question about a different input. A 700-character standalone essay post
is a legitimate reader item; a 700-character *web page* extraction is usually a
stub.

Calibration against real posts:

| Post | Body | Result |
| --- | --- | --- |
| X Article (`random_walker`) | 9 Draft.js blocks, 3 links | article (tier 1) |
| Long note tweet (`random_walker`) | 1774 | article |
| Note tweet (`karpathy`) | 797 | article |
| 6-post self-thread (`emollick`) | 1339 | article |
| 2-post aside (`emollick`) | 536 | **declined** |
| Standalone post (`karpathy`) | 182 | **declined** |
| Standalone post (`karpathy`) | 55 | **declined** |

## Threads

A chained thread is assembled into one article, in posting order. Two safeguards:

- **Author-only.** `/2/thread` is already author-only, but `authorThread` filters
  again by author id (falling back to handle) so a payload that ever included
  other people's replies can't splice strangers' text into someone's saved
  article. Identity prefers id over handle, since handles are renameable.
- **Position markers are removed.** People without a long-form composer number
  threads by hand, in the post body, which is the only place that information
  lives. Leaving them in makes "… 1/7" appear between every paragraph.

### Counter stripping

Only the very start and very end of a post are considered — a marker mid-sentence
is prose. Two shapes, with deliberately different confidence:

- **Open-ended** (`1/`, `2/n`, `4/?`) — a numerator over no denominator is never
  prose, so it is **always** stripped.
- **Closed** (`3/5`, `(2/7)`, `1.`, `2)`) — indistinguishable from an ordinary
  fraction, so it is stripped **only** when the chain shows a real scheme: at
  least two posts carry one *and* their numerators strictly ascend.

That ascending-scheme rule is what keeps "Add **1/2** cup of flour", "**3/5** of
respondents agreed", and a `9/11` date intact — a lone fraction in one post
establishes no scheme and is left exactly as written. Stripping also never
consumes an entire post.

Thread furniture is removed too: a leading/trailing 🧵 and an explicit `/end`,
`//end`, `/fin` marker.

## Media

Attached **photos** become `.image` blocks (with declared dimensions when the
payload has them) and contribute no text.

A post the user shared **because it holds a video** stays media and is declined —
converting it would strip the download the save was for. That judgment is made on
the post the URL actually **named** (`XPostPayload.sharedPost`), not the whole
chain: a long essay thread that happens to contain one clip further down is still
an essay, and its own video remains reachable from the post itself.

## The `html` half

`Outcome.article` carries source HTML, which the artifact stages downstream
consume rather than content: `ArticleCoverThumbnail` reads an `og:image` from it
for the card thumbnail, and `WebArchiveCapturer` archives it. There is no real
platform markup to carry here, so `XPostHTMLRenderer` renders the post we just
extracted into a small self-contained document (`og:` metadata, byline, blocks as
semantic HTML, escaped). Handing those stages an empty string would instead send
the archiver to capture x.com's **login wall**.

## Composition

The pipeline knows only a seam, `SocialTextIngestProcessing` (in LunaIngest),
returning `SocialTextArticle { content, html }`. This is the one kind whose routing
needs a network round-trip to decide — URL classification can tell that a link is
an X post, but not whether the post holds 40 characters or 4,000 — so
`IngestPipeline`'s `.social` branch offers every recognized social post to the
seam and takes an article only when one comes back.

`XPostIngestProcessor` (in **LunaArticleIngest**) implements it, and is registered
into `IngestKindProcessors.socialText` by the article-handling composition roots
only.

**Every article-handling SURFACE must register it, not just the app.** Each target
has several separate composition roots — the app shell, the share extension, the
action extension, the App Clip — and each is its own per-target file. Registering
in `KindWiring+*` alone was shipped once and produced exactly the confusing split
this warns about: a long X post saved *inside* the app read fine, while the same
link shared through the **share sheet** classified `.social` and was dropped with
"share media links to Luna Downloader". The seven roots:

| Surface | File |
| --- | --- |
| Luna app | `Luna/KindWiring+Luna.swift` |
| Reader app | `Luna/KindWiring+Reader.swift` |
| Luna share ext | `LunaShare/ShareEntry+Luna.swift` |
| Reader share ext | `LunaShare/ShareEntry+Reader.swift` |
| Luna action ext | `LunaAction/ActionEntry+Luna.swift` |
| Reader action ext | `LunaAction/ActionEntry+Reader.swift` |
| Reader App Clip | `LunaReaderClip/AppDelegate.swift` |

`SocialTextCompositionRootTests` enforces this by reading the composition-root
source: any file registering `IngestKindProcessors.article` without
`.socialText` fails the suite. No unit test can load the extensions themselves
(each registry is set in a principal class's initializer in a different process),
so the source check is the only thing tying these files together.

Per-app behavior:

| App | Registers `socialText` | X-post behavior |
| --- | --- | --- |
| `Luna` (central) | yes | long-form → article; short → social/media as before |
| `LunaReader` | yes | long-form → article; short → dropped (foreign kind) |
| `LunaDownloader` | no | unchanged — always `.social` |
| `LunaPriceTracker` | no | unchanged — always `.social` |

Because the implementation lives in LunaArticleIngest — a module only the two
article-handling apps link — the Downloader and Price Tracker carry none of this
code and cannot change behavior. Rerouting to `.article` also moves the outcome's
`owningApp` from `.downloader` to `.reader`, which is what puts the post in the
Reader's deck.

## Tests

- `XPostExtractorTests` (28) — the length gate (including that the threshold sits
  above 280, and that `is_note_tweet` is not the gate), X Article title + Draft.js
  block-kind mapping + entity-range links over the correct words, out-of-range
  entity dropped rather than clamped, thread assembly, foreign-reply exclusion,
  id-over-handle identity, dedupe, the video guard (and that a later clip does not
  disqualify), every counter-stripping rule with its false-positive guards, title
  derivation.
- `SocialTextCompositionRootTests` (4) — the composition-root invariant above (in
  both directions: an unguarded new root, and a deleted registration), plus that
  X's own `?s=46` / `?t=…` share params don't break post recognition or survive
  into the item id.
- `XPostIngestProcessorTests` (10) — endpoint order and request economy, the
  fallback path, non-X platforms and bad ids declined without fetching, and the
  pipeline branch: reroute to `.article` (Reader-owned), decline stays `.social`
  (Downloader-owned), unregistered processor leaves classification unchanged, and
  x.com is **never fetched**.

Fixtures in `LunaTests/Fixtures/XPosts/` are real fxtwitter responses trimmed to
the fields the extractor reads, so the tests exercise the true wire shape with no
network.

## Fragility

This depends on a third-party mirror of a hostile platform. If fxtwitter goes away
or changes shape, `XPostIngestProcessor` returns nil and **every X post silently
reverts to a social item** — the pre-existing behavior — rather than failing a
save. That is the intended degradation, and is why the processor treats every
error as "not readable" instead of `.failed`.
