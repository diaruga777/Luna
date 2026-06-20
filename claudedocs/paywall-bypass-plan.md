# Paywall-Bypass Robustness Plan

> **Audience:** the engineer (subagent 6) who will implement this. You have NOT done
> the research — this doc is self-contained. Read `claudedocs/readers.md` (current
> reader stack) and `claudedocs/archive-today-research.md` (prior archive.today
> research) for the surrounding context, but everything you need to build is here.
>
> **Goal:** replace today's narrow bypass ("archive.today WKWebView + NYT
> trailing-dot pre-stage") with a **data-driven, multi-strategy** pipeline that
> tries the cheapest, most reliable technique first and degrades gracefully — much
> closer to how Bypass Paywalls Clean (BPC) actually works.

---

## 0. Current state (what exists today)

Background, URLSession path (`ReaderKit/`):
- `ArticleFetcher.fetchHTML(from:)` — Googlebot UA first, Safari UA fallback, with a
  `Referer: https://www.google.com/`. Caps at 8 MB. **No per-host UA/referer rules,
  no cookie control, no JSON-LD body recovery.**
- `ArticleFetcher.fetchArchivedHTML` — Wayback Availability API, then
  `archive.ph/newest/<url>` (URLSession, usually CAPTCHA-blocked).
- `ArticleFetcher.canonicalForArchiving` — strips fragment + a fixed tracking-param
  set; unwraps archive URLs.
- `ArticleResolver.resolve` — `direct → AMP (rel=amphtml) → archived` →
  `.readable / .paywalled(title) / .unreadable`. AMP discovery already exists.
- `PaywallDetector` — content + schema.org/`article:content_tier` signals.
- `NYTPaywallBypass.trailingDotURL` — NYT-only trailing-dot transform.

User-visible WKWebView path:
- `ArchiveWebReaderViewController` — homepage warm-up → submit form / TimeMap
  snapshot → extract; NYT trailing-dot pre-stage; terminal messages + Safari escape.
- Pure, unit-tested decision cores: `decideStage`, `newestMemento(fromTimeMap:)`,
  `NYTPaywallBypass.trailingDotURL`.

The architecture is already strategy-shaped (one ordered fallback chain), it's just
**hardcoded and shallow**. This plan generalizes it.

---

## 1. Ranked techniques (reliability / cost / risk / who it helps)

"Cost" = round-trips + whether it needs a visible WKWebView. "Risk" = legal/ToS +
breakage. Publisher classes: **metered** (client-side counter, full body shipped),
**JS-gated** (body in DOM, vendor script hides it: Piano/tinypass, Poool, Evolok,
BlueConic), **hard server-side** (body never sent unauthenticated: WSJ/FT/Economist).

| # | Technique | Reliability 2026 | Cost | Risk | Helps |
|---|---|---|---|---|---|
| 1 | **JSON-LD `articleBody` extraction** from the page we already fetched | High where present (load-bearing for publisher SEO) | ~0 (parse only) | Low | metered, JS-gated, some "hard-ish" (Bloomberg, Telegraaf, Les Échos, NZ Herald) |
| 2 | **No-cookie / fresh-session fetch** (URLSession sends no cookies already) | Moderate, shrinking | 1 GET | Low | metered (client-side counter) |
| 3 | **Per-host UA spoof** (Googlebot desktop/mobile, Bingbot) | Low for IP-verifying majors; works on smaller + crawler-whitelist sites | 1 GET | Low–med | crawler-whitelist paywalls (Barron's, Handelsblatt, NZZ, Telegraph, Wired; Bingbot for Haaretz group) |
| 4 | **Per-host referer spoof** (google / facebook / twitter) | Medium, declining (First-Click-Free dead 2017) | 0 (header) | Low | social-virality sites (Bloomberg, fd.nl, Law360) |
| 5 | **AMP redirect / unhide** (`rel=amphtml`, `/amp`, `?outputType=amp`) | Low, falling (AMP de-emphasized since 2021) | 1 GET | Low | publishers still shipping a lightweight AMP template |
| 6 | **Trailing-dot FQDN** (`host` → `host.`) | Low–moderate, eroding | 1 GET | Low | client-side cookie/origin-keyed meters (NYT confirmed; spotty elsewhere) |
| 7 | **Wayback raw replay** `…/web/<ts>id_/<url>` after CDX/Availability lookup | Reliable WHEN a 200 snapshot exists; coverage poor for hard paywalls | 1–2 GET (JSON + HTML) | Low | anything Internet Archive crawled |
| 8 | **archive.today** (TimeMap read → snapshot, then WKWebView submit) | Best raw coverage, hostile to automation (CAPTCHA/DNS/IP) | WKWebView + CAPTCHA | Med | hard server-side (the only thing that works) |
| 9 | **r.jina.ai** (`https://r.jina.ai/<url>` → Markdown/HTML) | Reliable extractor, NOT a paywall breaker (fetches public page) | 1 GET | Low (3rd-party server) | generic fallback extraction; rate-limited 20 RPM no-key |
| 10 | **1ft.io** (`https://1ft.io/<url>`) | Live community 12ft successor; everywall/ladder-style server proxy that strips CORS + rewrites HTML → server-rendered, URLSession-extractable | 1 GET | Med (3rd-party) | soft/metered (proxy strips the gate) |
| 11 | **removepaywalls.com** (`https://removepaywalls.com/<url>`) | Live; proxies archive.is/Wayback/Google + JS-disable tricks. Renders client-side → WKWebView | WKWebView | Med (3rd-party) | broad publisher list (NYT/WaPo/WSJ/FT/Bloomberg/…); hit-or-miss |
| 12 | **removepaywall.com** (`https://www.removepaywall.com/search?url=<url>`) | Live; same archive-first family, distinct site. SPA → WKWebView | WKWebView | Med (3rd-party) | ~1-in-3 success in testing; broad list |
| 13 | **smry.ai** (`https://smry.ai/<url>`) | Alive, soft paywalls (~1k pubs); AI classifier over direct/proxy/Wayback. Next.js client app → WKWebView | WKWebView | Med (3rd-party) | last-ditch soft fallback |
| 14 | **archive.org / Wayback raw replay** (`…/web/<ts>id_/<url>` after CDX newest-200) | Same as #7; called out as an owner-required first-class fallback | 1–2 GET | Low | anything IA crawled (silent) |
| — | `X-Forwarded-For` spoof | ~Zero vs correct servers | 0 | Low | only misconfigured IP allowlists — **skip** |
| — | Google cache / Bing cache / 12ft.io | **DEAD** (2024–25) | — | — | **do not implement** |
| — | RSS full-text | High where it exists, rare for hard paywalls | 1 GET | Low | indie outlets (404 Media, some Ghost) — optional later |

> **Owner correction (overrides the original "drop dead services" stance):** the goal
> is *more* fallbacks than archive.is and smart selection among them. smry.ai, 1ft.io,
> removepaywall.com, removepaywalls.com, archive.org/Wayback, AND archive.today are all
> implemented as first-class `BypassStrategy` fallbacks with graceful failure (a dead
> one just falls through to the next via the readability gate). Verified request formats
> + silent-vs-webview classification are encoded in `ThirdPartyBypassService` (see §5a)
> and the seed rule table.

**Silent vs WKWebView classification of the third-party services**
(silent = its response is server-rendered HTML a `URLSession` GET can extract;
WKWebView = a JS/SPA app whose article only materializes after client-side render):

| Service | Request format | Class |
|---|---|---|
| Wayback raw | `https://web.archive.org/web/<ts>id_/<url>` (CDX newest-200 first) | **silent** (`.waybackRaw`) |
| 1ft.io | `https://1ft.io/<url>` (raw URL appended) | **silent** (`.ladderProxy(.oneFt)`) |
| r.jina.ai | `https://r.jina.ai/<url>` | **silent** (`.jinaReader`) |
| removepaywalls.com | `https://removepaywalls.com/<url>` (raw URL appended) | **WKWebView** (`.thirdPartyWeb(.removePaywalls)`) |
| removepaywall.com | `https://www.removepaywall.com/search?url=<url-encoded>` | **WKWebView** (`.thirdPartyWeb(.removePaywall)`) |
| smry.ai | `https://smry.ai/<url>` (raw URL appended) | **WKWebView** (`.thirdPartyWeb(.smry)`) |
| archive.today | homepage→submit / TimeMap snapshot | **WKWebView** (`.archiveToday`, terminal) |

**Design consequence:** the durable techniques exploit the publisher's own SEO/social
obligations (JSON-LD body #1, social referer #4, crawler UA #3) and client-side state
weaknesses (no-cookie #2, trailing-dot #6). Identity forgery alone (UA, XFF) is dead
wherever the server verifies crawler identity by reverse-DNS (most majors / anything
behind Cloudflare bot management). So **#1 and #2 are the highest-yield, lowest-effort
wins** and should run on every paywalled page before anything network-heavy. The
third-party services (#10–13, #8) are last in the order — they shift legal liability off
us but die periodically, so they sit behind the on-device techniques and degrade to "try
the next one."

---

## 2. Strategy-selection design

### 2.1 The `BypassStrategy` enum

New file `ReaderKit/BypassStrategy.swift`. A strategy is **either** a request
transform (run silently in `URLSession`) **or** a flag for the WKWebView path. Make
the silent/visible split explicit in the type so the resolver and the web reader can
each filter to the strategies they can run.

```swift
/// One technique for getting a readable article past a paywall. Ordered lists of
/// these are produced by `BypassStrategySelector`. Each case is either
/// `runsSilently` (a URLSession request transform usable in the background ingest
/// path) or WKWebView-only (user-visible, needs a real browser/JS/CAPTCHA).
enum BypassStrategy: Equatable {
    /// Re-parse the HTML we already have, lifting the full body out of a
    /// `<script type="application/ld+json">` articleBody. Zero network. Silent.
    case jsonLDBody
    /// Re-fetch with a specific crawler User-Agent (+ matching Googlebot XFF).
    case userAgent(CrawlerAgent)
    /// Re-fetch sending a spoofed Referer (and otherwise normal UA). Silent.
    case referer(RefererOrigin)
    /// Re-fetch the trailing-dot FQDN variant of the host. Silent (URLSession) AND
    /// usable in WKWebView (the NYT pre-stage today).
    case trailingDotHost
    /// Re-fetch with no cookies / a fresh ephemeral session. Silent.
    case freshSession
    /// Discover the AMP URL (rel=amphtml or a host-specific suffix) and fetch it.
    case amp
    /// Wayback: resolve newest 200 snapshot (CDX/Availability) then fetch the raw
    /// `id_` replay. Silent.
    case waybackRaw
    /// r.jina.ai reader proxy (`https://r.jina.ai/<url>`) → Markdown/HTML. Silent.
    case jinaReader
    /// A server-rendering proxy (1ft.io) whose response is plain HTML a URLSession
    /// can extract. Silent.
    case ladderProxy(LadderProxy)
    /// A third-party reader page that only renders client-side (smry.ai,
    /// removepaywall(s).com). WKWebView-only.
    case thirdPartyWeb(ThirdPartyWebService)
    /// archive.today snapshot via the interactive WKWebView reader. WKWebView-only,
    /// always terminal.
    case archiveToday

    /// Whether this strategy can run in the background URLSession path. The
    /// client-rendered third-party pages and archive.today are not silent.
    var runsSilently: Bool {
        switch self {
        case .archiveToday, .thirdPartyWeb: return false
        default: return true
        }
    }
}

/// Crawler identities a paywall may whitelist for SEO/social. `xForwardedFor`
/// carries a real crawler IP so server-side reverse-DNS-lite checks pass.
enum CrawlerAgent: Equatable {
    case googlebotDesktop, googlebotMobile, bingbot
    var userAgent: String { /* literal UA strings, see §5 */ }
    var xForwardedFor: String? { /* "66.249.66.1" for googlebot, nil for bing */ }
}

/// Referer origins that trip "came from search/social" free-read allowances.
enum RefererOrigin: String, Equatable {
    case google, facebook, twitter
    var url: String { /* https://www.google.com/ | https://www.facebook.com/ | https://t.co/ */ }
}
```

### 2.2 The per-host rule table (`BypassRuleTable`)

A data-driven table mirroring BPC's `sites.js` — the single source of truth for
"what do we try for host X, in what order." Keep it a **static Swift literal** (no
remote config in v1 — that's a future hardening step, see §7). New file
`ReaderKit/BypassRuleTable.swift`.

```swift
/// A per-host bypass rule: the ordered strategies to try and the request tweaks
/// they need. Modeled on Bypass Paywalls Clean's per-site object so it's easy to
/// port their rules. Absent fields mean "default" (strip cookies, normal UA).
struct BypassRule: Equatable {
    /// Registrable domain this rule matches (apex; also matches subdomains).
    let domain: String
    /// Ordered silent strategies to try in the background path, best first.
    let strategies: [BypassStrategy]
    /// When set, send cookies on the request (some sites need a logged-out cookie).
    let allowCookies: Bool
    /// JSON-LD selector hint "paywallSelector|articleSelector" (optional; the
    /// extractor's existing articleBody fallback works without it).
    let ldJSONSelector: String?
}

enum BypassRuleTable {
    /// Looks up the rule for a URL's host (apex or subdomain match), or nil.
    static func rule(for url: URL) -> BypassRule? { /* host-suffix match */ }

    /// The seed rule set. Port more from BPC's sites.js over time.
    static let rules: [BypassRule] = [
        BypassRule(domain: "nytimes.com",  strategies: [.trailingDotHost, .waybackRaw, .archiveToday], allowCookies: false, ldJSONSelector: nil),
        BypassRule(domain: "barrons.com",  strategies: [.userAgent(.googlebotDesktop), .amp, .waybackRaw, .archiveToday], allowCookies: false, ldJSONSelector: nil),
        BypassRule(domain: "wsj.com",      strategies: [.userAgent(.googlebotDesktop), .waybackRaw, .archiveToday], allowCookies: false, ldJSONSelector: nil),
        BypassRule(domain: "ft.com",       strategies: [.userAgent(.googlebotDesktop), .waybackRaw, .archiveToday], allowCookies: false, ldJSONSelector: nil),
        BypassRule(domain: "bloomberg.com",strategies: [.jsonLDBody, .referer(.twitter), .referer(.facebook), .waybackRaw, .archiveToday], allowCookies: false, ldJSONSelector: nil),
        BypassRule(domain: "haaretz.com",  strategies: [.userAgent(.bingbot), .waybackRaw, .archiveToday], allowCookies: false, ldJSONSelector: nil),
        // …seed ~20 hosts from ArticleFetcher.hardPaywallHosts + BPC's top entries.
    ]
}
```

### 2.3 The selector (`BypassStrategySelector`)

The pure function (no I/O) that, given a URL **and** the already-fetched direct HTML
(so it can read paywall signals), returns the ordered strategy list. This is the
heavy-test target.

```swift
enum BypassStrategySelector {
    /// Ordered strategies to try for `url`, given the direct page's HTML (nil if the
    /// direct fetch failed). Pure — no I/O — so it's fully unit-testable.
    ///
    /// Order of reasoning:
    /// 1. If the page isn't paywalled at all → return [] (caller already has it).
    /// 2. If a per-host rule exists → use its strategy list verbatim (BPC parity).
    /// 3. Otherwise build a generic list from the paywall signals:
    ///    - JSON-LD articleBody present in HTML → lead with .jsonLDBody.
    ///    - content_tier == metered (or no schema lock) → .freshSession, .trailingDotHost.
    ///    - always append the universal fallbacks: .amp, .waybackRaw, .jinaReader, .archiveToday.
    static func strategies(for url: URL, directHTML: String?) -> [BypassStrategy]
}
```

Selection rules in plain English:
- **Not paywalled** (`!PaywallDetector.looksPaywalled` and body is readable) → `[]`.
- **Per-host rule hit** → its `strategies` (already ordered by what works for that
  publisher). This is where BPC's hard-won per-site knowledge lives.
- **Generic fallback** (unknown host, paywalled): always cheap-first —
  `[.jsonLDBody (if HTML has articleBody), .freshSession, .trailingDotHost, .amp, .waybackRaw, .jinaReader, .archiveToday]`. Drop `.jsonLDBody` when the HTML carries no
  ld+json articleBody; drop `.trailingDotHost`/`.freshSession` when schema declares a
  hard `locked` tier (cookie/origin tricks can't beat server-side).
- **De-dup + ordering invariant:** silent strategies always precede WKWebView-only
  ones; `.archiveToday` is always last (most expensive/hostile).

### 2.4 How it slots into `ArticleResolver.resolve` (background, URLSession)

`resolve` becomes: direct fetch → if readable return → else **run the silent
strategy list** until one yields a readable, non-locked extraction → else return
`.paywalled(title)` (so the WKWebView path is still offered for the WKWebView-only
strategies). Concretely:

```swift
static func resolve(url:fetcher:extractor:) async -> ArticleResolution {
    let direct = await extractedContent(...)            // unchanged
    if isReadable(direct) { return .readable(...) }

    let strategies = BypassStrategySelector.strategies(for: url, directHTML: direct?.1)
    for strategy in strategies where strategy.runsSilently {
        if let pair = await BypassRunner.run(strategy, url: url, directHTML: direct?.1,
                                             fetcher: fetcher, extractor: extractor),
           isReadable(pair) {
            return .readable(pair.0, html: pair.1)
        }
    }
    // No silent strategy worked — preserve the title so the item parks for the
    // WKWebView archive path (unchanged downstream behavior).
    return resolution(direct: direct, archived: nil)
}
```

`BypassRunner` is the **only** new I/O class (protocol + mock + tests). It maps a
`BypassStrategy` to the concrete `ArticleFetcher` call:
- `.jsonLDBody` → re-extract `directHTML` via the extractor's JSON-LD articleBody
  layer (already exists in `ArticleExtractor` — expose it / force it).
- `.userAgent(agent)` → `fetcher.fetch(url, userAgent: agent.userAgent, xff: agent.xForwardedFor)`.
- `.referer(origin)` → `fetcher.fetch(url, referer: origin.url)`.
- `.trailingDotHost` → `fetcher.fetchHTML(from: NYTPaywallBypass.trailingDotURL-generalized)` (rename to `TrailingDotBypass.trailingDotURL`, drop the NYT-only host guard — see §3).
- `.freshSession` → fetch via an **ephemeral** `URLSession` (no cookie store).
- `.amp` → reuse `ArticleResolver.ampURL(in:base:)`, then fetch.
- `.waybackRaw` → new `fetcher.fetchWaybackRawHTML(for:)` (CDX newest-200 → `id_` replay; see §4).
- `.jinaReader` → `fetcher.fetchJinaReader(for:)`.
- `.archiveToday`, `.smry` → not silent; `run` returns nil for them.

This keeps `ArticleResolver` thin and leaves the existing
`.readable/.paywalled/.unreadable` → ingestor-state mapping **unchanged** (no risk to
the `needsCaptcha` flow that the extensions depend on).

### 2.5 How it slots into `ArchiveWebReaderViewController` (WKWebView, visible)

Today the VC hardcodes: NYT trailing-dot pre-stage → archive.today. Generalize it to
**consume the same strategy list**, filtered to WKWebView-appropriate ones, run in
order, each as a pre-stage before the next:

- Compute `let webStrategies = BypassStrategySelector.strategies(for: articleURL, directHTML: nil).filter { needsWebView($0) }` where `needsWebView` = `.trailingDotHost`, `.amp`, `.smry`, `.archiveToday` (the ones worth a real browser/JS; the silent ones already ran in the background path and failed, so don't repeat them here unless they benefit from JS rendering — `.trailingDotHost` and `.amp` do, because the paywall JS runs client-side).
- Keep the existing `checkDirectBypassStage` machinery but make it **strategy-indexed**: a `currentWebStrategyIndex`; `fallBackToArchiveFromBypass` becomes `advanceToNextWebStrategy` (load the next strategy's URL, or fall into the archive.today flow when the list is exhausted). `archiveToday` stays the terminal element and reuses ALL the current homepage/TimeMap/submit/terminal-message code verbatim.
- The poll/extract loop is unchanged: each pre-stage page is just "load URL, poll innerText length, try `extractAndSave`, advance on timeout." `smry`/`amp`/`trailingDot` all fit that exact shape (`checkDirectBypassStage` already does it).

Net: the VC's flow generalizes from "NYT? then archive : archive" to "walk the
web-strategy list, archive.today last," with **zero change to the archive.today
core** (the riskiest code). The NYT pre-stage becomes the `.trailingDotHost` element
that the selector emits for nytimes.com.

---

## 3. Generalize the trailing-dot bypass

Rename `NYTPaywallBypass` → `TrailingDotBypass` (keep a thin NYT shim if other code
references it, or update callers — there's one, the VC's `directBypassURL`). The
transform itself (`host` → `host.`, preserving path/query, idempotent on an existing
trailing dot) is **publisher-agnostic** — the only NYT-specific thing is the host
allowlist, which we drop. The selector decides *when* to apply it (per-host rule, or
the generic metered branch), so the URL transform no longer needs to gate on host.
Keep `NYTPaywallBypassTests` (rename to `TrailingDotBypassTests`); add cases for
non-NYT hosts now that the host guard is gone.

Reported to work beyond NYT on other client-side cookie/origin-keyed meters; spotty,
so it's a *cheap try*, never a guarantee. (Source: HN 32863009, 41982974; Medium
soltanali0 "trailing dot trick".)

---

## 4. Wayback raw-replay strategy (new, silent, high-value)

Today `fetchWaybackHTML` uses the Availability API + the **rewritten** replay. Add a
sharper path used by `.waybackRaw`:

1. **CDX newest 200:** `GET https://web.archive.org/cdx/search/cdx?url=<canonical>&output=json&filter=statuscode:200&collapse=digest&limit=-5&fastLatest=true` → JSON rows `[urlkey,timestamp,original,mimetype,statuscode,digest,length]`. Take the newest row's timestamp. (`limit=-5` = last 5; pick the newest that isn't tiny by `length`.)
2. **Raw replay:** fetch `https://web.archive.org/web/<timestamp>id_/<original>` — the `id_` suffix strips IA's banner/asset rewriting, giving un-mangled source HTML the extractor likes.
3. Fall back to the existing Availability-API replay if CDX returns nothing.

Pure-testable piece: a `newestSnapshotTimestamp(fromCDXJSON:)` parser (mirrors
`newestMemento(fromTimeMap:)`). Network piece lives in `ArticleFetcher`.
(Sources: archive.org/help/wayback_api.php; internetarchive/wayback CDX README.)

---

## 5. JSON-LD articleBody recovery (new, silent, highest-yield)

`ArticleExtractor` already has a JSON-LD `articleBody` layer in its fallback chain.
For `.jsonLDBody`, **force that layer** on the direct HTML even when the rendered body
looked paywalled — many publishers ship `"isAccessibleForFree": false` alongside a
**fully populated** `articleBody` (Bloomberg, Telegraaf, Les Échos, NZ Herald). Add
`ArticleExtractor.extractFromJSONLD(html:baseURL:) -> ArticleContent?` (pure, testable
with a fixture) that:
- finds every `<script type="application/ld+json">`, JSON-parses each,
- walks for a `NewsArticle`/`Article` node (handle `@graph` arrays and `hasPart`),
- returns its `articleBody` (+ `headline`, `author`) as blocks.

Then `.jsonLDBody` is a zero-network re-parse of `directHTML`. Run it FIRST in the
generic paywalled branch (cheapest possible). (Sources:
developers.google.com structured-data/paywalled-content; schema.org/NewsArticle;
BPC `ld_json` field + `getArticleJsonScript()`.)

**UA strings** (from BPC/iamadamdev source, for `CrawlerAgent`):
- googlebotDesktop: `Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)` + XFF `66.249.66.1`
- googlebotMobile: `Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.92 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)` + XFF `66.249.66.1`
- bingbot: `Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)` (no XFF)

Note: many majors now **IP-verify** crawlers (reverse-DNS), so UA+XFF spoofing fails
for them — that's why per-host rules pick UA only for sites known to honor it, and
the universal fallback never relies on UA alone.

---

## 5a. Third-party bypass-service URL builders (`ThirdPartyBypassService`)

A pure namespace of verified URL builders for the owner-required third-party
services. Each builder takes the canonical article URL and returns the service URL.
All are unit-tested against the verified formats below; the runner/web-reader just
load what they return. A nil return (e.g. an un-encodable URL) makes the strategy
fall through.

```swift
/// Silent (URLSession-extractable) ladder-style proxies. 1ft.io is the live
/// everywall/ladder-family successor to 12ft.io; it server-renders the article.
enum LadderProxy: Equatable {
    case oneFt   // https://1ft.io/<raw article URL>
    func url(for article: URL) -> URL?
}

/// Client-rendered third-party reader pages (need a real WKWebView to render).
enum ThirdPartyWebService: Equatable {
    case smry            // https://smry.ai/<raw article URL>
    case removePaywalls  // https://removepaywalls.com/<raw article URL>
    case removePaywall   // https://www.removepaywall.com/search?url=<percent-encoded>
    func url(for article: URL) -> URL?
}
```

**Verified request formats (WebSearch/WebFetch, June 2026):**

| Service | Builder output | Source class |
|---|---|---|
| 1ft.io | `https://1ft.io/` + `article.absoluteString` (raw, no extra encoding — 12ft-style prefix) | silent |
| smry.ai | `https://smry.ai/` + `article.absoluteString` (raw path prefix; confirmed on smry.ai/guide) | webview |
| removepaywalls.com | `https://removepaywalls.com/` + `article.absoluteString` (raw path prefix) | webview |
| removepaywall.com | `https://www.removepaywall.com/search?url=` + percent-encoded `article.absoluteString` (query param) | webview |
| Wayback raw | `https://web.archive.org/web/<ts>id_/<original>` after CDX newest-200 (`ArticleFetcher.fetchWaybackRawHTML`) | silent |

Note the encoding split: the three path-prefix services append the article URL **raw**
(keeping its own `https://` and slashes, like archive.today's path style); only
removepaywall.com percent-encodes it because it's a real query-parameter value.

---

## 6. Test plan (maximize coverage without the network)

**Pure / unit-testable (target ~all logic here):**
- `BypassStrategySelectorTests` — given (host, HTML fixture) → expected ordered list.
  Cases: not-paywalled→[]; per-host rule hit returns its list; generic metered branch;
  generic locked branch drops cookie/dot tricks; JSON-LD present vs absent toggles
  `.jsonLDBody`; de-dup; silent-before-webview invariant; archiveToday always last.
- `BypassRuleTableTests` — apex + subdomain matching; unknown host → nil; trailing dot.
- `TrailingDotBypassTests` (was `NYTPaywallBypassTests`) — transform on NYT + non-NYT
  hosts; idempotent on existing dot; preserves path/query; nil on hosts with no dot
  benefit only if you keep a guard (we don't — so it transforms any host).
- `ArticleExtractor.extractFromJSONLDTests` — fixtures: full articleBody present →
  blocks; `@graph` wrapper; `hasPart` paywalled section; no ld+json → nil; truncated
  articleBody (shorter than `readableBodyThreshold`) → still parsed, lets
  `hasReadableBody` reject it.
- `ArticleFetcher.newestSnapshotTimestamp(fromCDXJSON:)Tests` — newest row, empty
  array, malformed JSON, all-non-200 filtered out.
- `CrawlerAgent` / `RefererOrigin` value tests — UA/XFF/referer string mapping.
- `BypassRunner` with a **mock `ArticleFetcher`** (protocol-ize the fetch surface):
  asserts each strategy calls the right fetch with the right UA/referer/XFF/URL, and
  that `.archiveToday`/`.smry` return nil (not silent).

**Network-dependent (manual / integration only, mark `XCTSkip` in CI):**
- Live Wayback CDX/raw fetches, live r.jina.ai, live archive.today — exercised by
  hand on-device (per CLAUDE.md, camera-style un-simulatable paths are mocked; these
  are network paths → mock the `ArticleFetcher` protocol in unit tests and smoke-test
  live manually).

Protocol-ize `ArticleFetcher` (introduce `ArticleFetching` protocol + the existing
struct as the live impl + a `MockArticleFetcher`) so `BypassRunner` and the resolver
are testable without the network. `ArticleResolver` already takes a `fetcher`
parameter — widen its type to the protocol.

---

## 7. Risks, legality, ToS, rate limits

**Legal (the load-bearing risk):** paywall-bypass tooling is being killed by the
**News/Media Alliance via DMCA §1201 anti-circumvention** ("trafficking in
circumvention technology," no safe harbor), not primarily by Apple guidelines. BPC was
removed from Firefox AMO (2023), GitLab (2024), and GitHub + ~3,879 forks (Aug 2024);
12ft.io was taken offline by its host (Jul 2025). (Sources: TorrentFreak BPC §1201;
github/dmca 2024-08-09 NMA notice; AlternativeTo 12ft.)

**App Store:** Apple's hook is **Guideline 5.2.2** (must be authorized by the
third-party service's ToS — a bypass never is; "authorization upon request") plus
**5.2.1/5.2.3** (IP / unauthorized media download) and **2.3.1** (don't *market* the
bypass). No publicly documented case of Apple pulling a named bypass app on 5.2.2 was
found, but surviving apps (e.g. Praxis) **carefully position as privacy/ad-blocking**
("blocks cookies/JS/ads"), never "we crack paywalls." **Implication for us:**
- Do the work **on-device** (URLSession transforms + WKWebView) — never proxy/host
  article text on our own server (that's the §1201 "trafficking" exposure that killed
  12ft/BPC). Redirecting to a third party (archive.today, r.jina.ai, smry) shifts
  liability but makes us dependent on services that keep dying — keep them as *optional
  fallbacks behind a flag*, not the core.
- Keep marketing/UX framed as a **reader/offline-saver** ("Unlocking article…" is
  fine; don't add copy that advertises defeating specific publishers).
- Treat the per-host rule table as the place a takedown would target; keeping it a
  static in-app literal (not a fetched remote list) avoids a server we'd have to take
  down, but also means updates ship with the app. (A future remote rule list is a
  liability tradeoff — note it, don't build it in v1.)

**Rate limits / good-citizen handling:**
- **r.jina.ai:** 20 RPM unauthenticated. Use it sparingly (low in the fallback order),
  back off on 429, and ship an API key (500 RPM) only if volume warrants.
- **Wayback:** soft-throttles bulk use with 429 — set a clear UA, back off, cache the
  resolved snapshot URL per article (we already persist content once extracted).
- **archive.today:** the existing 429-loop + stall-guard + terminal-message handling
  in `ArchiveWebReaderViewController` stays as-is; it's the right model. Don't hammer
  `/submit/`; prefer the TimeMap read path (already implemented).
- Per-strategy timeouts already exist (`ArticleFetcher.fetch(timeout:)`); keep silent
  strategies short (≤12s) so the foreground share sheet never stalls — the chain
  should fail fast to the parked `.needsCaptcha` state, which is non-blocking.

**Breakage:** every technique erodes as publishers patch. The table + selector make
each technique independently removable/reorderable, and the readability gate
(`hasReadableBody` + `htmlDeclaresLocked`) is the final arbiter, so a stale rule
degrades to "try the next strategy," never to a wrong/garbled article.

---

## 8. Build order (for subagent 6)

1. **Pure types first** (API-first per CLAUDE.md, `fatalError` bodies): `BypassStrategy`,
   `CrawlerAgent`, `RefererOrigin`, `BypassRule`, `BypassRuleTable`,
   `BypassStrategySelector`, `ArticleFetching` protocol, `BypassRunner` protocol.
2. **Write the unit tests** in §6 against those signatures (they'll fail / fatalError).
3. **Implement the pure cores:** selector, rule table, trailing-dot generalization,
   JSON-LD extractor layer, CDX timestamp parser. Make §6 pure tests pass.
4. **Implement the I/O:** `BypassRunner` + new `ArticleFetcher` methods
   (`fetchWaybackRawHTML`, `fetchJinaReader`, fetch with UA/XFF/referer/ephemeral).
   Test with `MockArticleFetcher`.
5. **Wire `ArticleResolver.resolve`** to the silent strategy loop (§2.4). Run the full
   `ArticleResolverTests` suite — the `.readable/.paywalled/.unreadable` outcomes must
   be unchanged for existing fixtures.
6. **Generalize `ArchiveWebReaderViewController`** to the web-strategy list (§2.5),
   keeping the archive.today core untouched. Keep `ArchiveStageDecisionTests` green.
7. **Update `claudedocs/readers.md`** ("Hard-paywall resolution & archive reader"
   section) to describe the strategy pipeline; this plan can then be deleted or kept as
   design rationale.

Commit in those steps (many small commits per CLAUDE.md). Run tests after each.

---

## Sources

Reader services / status:
- 12ft death: https://en.wikipedia.org/wiki/12ft ; https://alternativeto.net/news/2025/7/news-publishers-secure-takedown-of-popular-12ft-ladder-paywall-bypass-website/
- smry.ai: https://smry.ai/guide ; https://github.com/caffo/SMRY/
- Wayback Availability: https://archive.org/help/wayback_api.php
- Wayback CDX: https://github.com/internetarchive/wayback/blob/master/wayback-cdx-server/README.md
- r.jina.ai: https://jina.ai/reader/
- freedium: https://github.com/Freedium-cfd

HTTP-level techniques:
- JSON-LD paywalled content: https://developers.google.com/search/docs/appearance/structured-data/paywalled-content ; https://schema.org/NewsArticle
- Incognito / metered: https://www.niemanlab.org/2019/06/publishers-will-soon-no-longer-be-able-to-detect-when-youre-in-chromes-incognito-mode-weakening-paywalls-everywhere/
- Referer / First-Click-Free: https://searchengineland.com/wsj-first-click-free-269545 ; https://docs.leakypaywall.com/article/195-how-to-allow-a-user-to-bypass-the-meter-based-on-referrer-or-url
- Googlebot/Bingbot UA + IP verification: https://news.ycombinator.com/item?id=26593619 ; https://searchengineland.com/guide/what-is-googlebot-fraud ; https://www.bing.com/webmasters/help/how-to-verify-bingbot-3905dc26
- Trailing-dot trick: https://soltanali0.medium.com/bypassing-origin-checks-using-trailing-dot-trick-a65007041d3a ; https://news.ycombinator.com/item?id=32863009 ; https://news.ycombinator.com/item?id=41982974
- AMP cache URL format: https://amp.dev/documentation/guides-and-tutorials/learn/amp-caches-and-cors/amp-cache-urls
- X-Forwarded-For (don't trust): https://www.acunetix.com/vulnerabilities/web/x-forwarded-for-http-header-security-bypass/
- RSS full-text: https://www.404media.co/404-media-now-has-a-full-text-rss-feed/

Bypass Paywalls Clean / iamadamdev (rule-set source):
- BPC readable mirror: https://github.com/csns1/bypass-paywalls-chrome-clean-magnolia1234 (sites.js, background.js, contentScript.js)
- iamadamdev readable mirror: https://github.com/xxooomg/iamadamdev-bypass-paywalls-chrome
- BPC current home: https://gitflic.ru/user/magnolia1234
- Overview: https://en.wikipedia.org/wiki/Bypass_Paywalls_Clean

iOS apps / legality:
- Praxis: https://apps.apple.com/us/app/praxis-ad-free-news-browser/id1598706451 ; https://praxisnews.app/
- NewsPal: https://apps.apple.com/pk/app/newspal-offline-browser/id1501637899
- Apple guidelines: https://developer.apple.com/app-store/review/guidelines/
- NMA DMCA takedowns: https://torrentfreak.com/bypass-paywalls-clean-shut-down-for-dmca-anti-circumvention-violations-240820/ ; https://github.com/github/dmca/blob/master/2024/08/2024-08-09-news-media-alliance.md
