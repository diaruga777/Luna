# Reading paywalled articles via archive.today on iOS — research report

Date: 2026-06-19. Scope: how to programmatically resolve/read archive.today snapshots of hard-paywalled articles (WSJ, FT) from an iOS client, whether the "homepage warm-up" theory holds, and ranked alternatives. No live requests were made to archive.today; findings rest on library source, ArchiveTeam/Wikipedia docs, Cloudflare docs, and forum/GitHub reports.

---

## Headline conclusions

1. **The warm-up theory is most likely WRONG for the reason you think.** archive.today's solve→re-challenge loop is dominated by (a) a **DNS/EDNS dispute** that sinkholes the domain over Cloudflare/Firefox DoH resolvers, and (b) archive.today's **own reCAPTCHA** (not Cloudflare's challenge), which only grants ~5 minutes of access per solve. Loading the homepage first fixes neither. There is **no sourced report** of a homepage warm-up curing the loop on archive.today specifically.
2. **The lightest, most reliable archive.today path is a READ, not a submit.** Resolve the newest snapshot via the Memento **TimeMap** (`/timemap/<url>`, link-format text containing directly-loadable snapshot URLs) or `/timegate/<url>`, then load the specific `/<shortid>` or `/<datetime>/<url>` snapshot. The CAPTCHA/429 wall is documented specifically on the **`/submit/` write path**, not on reads. (Confidence: likely — code-evidenced, not first-hand verified.)
3. **The best clean, no-CAPTCHA programmatic API is the Wayback CDX API**, but its *content* coverage for hard-paywalled WSJ/FT is poor and declining (FT blocks the IA crawler; broad publisher blocking accelerated through 2025–2026).
4. **For true hard paywalls the body text often does not exist outside a subscription.** Google Cache, Bing Cache, 12ft.io, and the public Memento aggregator are all DEAD as of 2024–2026.

---

## (1) archive.today URL formats & request mechanics

| Endpoint | Purpose | Confidence |
|---|---|---|
| `/<url>` (bare) | Lists ALL captures of the URL (overview page, not one snapshot) | confirmed |
| `/newest/<url>` | Redirects to most-recent snapshot (TimeGate-like) | confirmed (302→`/<shortid>` likely) |
| `/oldest/<url>` | Earliest capture | likely (symmetric) |
| `/<YYYYMMDDhhmmss>/<url>` | Canonical timestamped snapshot | confirmed |
| `/<SHORTID>` | Short snapshot URL — 5 case-sensitive alphanumerics (4 on early-2012) | confirmed |
| `/timegate/<url>` | Memento TimeGate (latest) | confirmed |
| `/timemap/<url>` | Memento TimeMap (RFC 7089 link-format list of snapshots) | confirmed endpoint exists |
| `/submit/?url=` + POST `/submit/` | Submit a NEW snapshot | confirmed |
| `…/<SHORTID>/<timestamp>id_/<url>` | Raw/no-frame variant (no archive overlay) | likely (Memento convention, not archive.today-specific doc) |

**URL encoding:** In **path-style** endpoints (`/newest/`, `/<timestamp>/`, `/timemap/`) the target URL is appended **RAW/unencoded**, keeping its own `https://` and slashes, e.g. `https://archive.is/newest/https://wsj.com/articles/foo`. In the **form POST** the URL is an ordinary `application/x-www-form-urlencoded` field. (Confirmed: ArchiveTeam wiki example; library source splices raw into path.)

**Homepage submit form:** POST to `/submit/`. Field is named `url` (input `id="url"`); the search/lookup box uses `q`. The form carries a hidden anti-bot token `submitid` that you must GET-then-echo. Full historical POST body: `anyway=1&url=<target>&submitid=<scraped>`. A browser-like User-Agent is mandatory ("without a user agent, force archiving won't work"). Result URL is returned via the **`Refresh` header** (`Refresh: 0;url=<snapshot>`) on 200, or `Location` on 302/307; `/wip/` links are polled until they redirect. (Confirmed: archivenow, palewire/archiveis, HRDepartment/archivetoday, jaytaylor source.)

**Hostname rotation:** Service rotates across `.today/.is/.ph/.md/.li/.vn` (`.fo` revoked 2019; `.ec`/Tor onion also exist). Clients re-read the host from the redirected index URL before POSTing, and iterate the TLD list until one responds.

Sources: ArchiveTeam wiki (https://wiki.archiveteam.org/index.php/Archive.today), Wikipedia Archive.today (https://en.wikipedia.org/wiki/Archive.today), archivenow `is_handler.py` (https://github.com/oduwsdl/archivenow).

---

## (2) The CAPTCHA loop — root causes & the warm-up theory

**Critical reframing:** archive.today's "prove you are human" gate is largely **archive.today's OWN reCAPTCHA/hCaptcha**, not Cloudflare's branded challenge. Two distinct loop mechanisms get conflated:

**(A) DNS / EDNS Client Subnet dispute — CONFIRMED, dominant cause.** archive.today's authoritative DNS refuses to answer correctly unless the query carries EDNS Client Subnet (RFC 7871). Cloudflare's resolver (1.1.1.1) and Firefox's default DoH (which routes via Cloudflare) **don't send ECS**, so archive.today returns a bogus/sinkhole A record (e.g. `1.1.1.4`, historically `127.0.0.3`) → non-resolution or endless challenge. **Fix: use Google 8.8.8.8 or any ECS-respecting resolver, or disable DoH.** Status is intermittent (reportedly fixed Aug 2024, broken again into 2026).
Sources: https://gist.github.com/ardislu/b2f2b4b439c5da2f7ccb6bb42e7a8882, https://news.ycombinator.com/item?id=38246073, https://news.ycombinator.com/item?id=35841308

**(B) archive.today's reCAPTCHA — CONFIRMED.** A solve grants only ~5 minutes of access before re-prompting (ArchiveTeam wiki). VPN/proxy/datacenter IPs get persistent challenges. Contributing factors (likely): non-mainstream/mismatched User-Agent; third-party-cookie blocking breaking the cross-domain (.is/.ph/.vn) CAPTCHA hand-off; aggressive privacy extensions/anti-fingerprinting.

**Does loading the homepage first help? — NO sourced evidence it does (for archive.today).**
- No forum/GitHub thread describes a homepage warm-up curing archive.today's loop.
- Indirect Cloudflare logic *would* support it IF the loop were Cloudflare's: a valid `cf_clearance` is zone-wide and bypasses challenges on other paths (Cloudflare docs). But archive.today's loop is mostly the DNS issue + its own reCAPTCHA, **neither of which a homepage visit fixes.**
- Verdict: **theory refuted as a general fix.** Your user's one-off success is better explained by a transient DNS/IP/UA state than by the warm-up itself. The deep `/newest/<url>` cold-hit isn't the root cause; **DNS and IP reputation are.**

Sources: Cloudflare clearance scope (https://developers.cloudflare.com/cloudflare-challenges/concepts/clearance/), ArchiveTeam wiki, https://lemmy.world/post/33242183, https://news.ycombinator.com/item?id=38173709

---

## (3) How the unofficial libraries do it

All pure-HTTP clients share ONE protocol and **none solve Cloudflare/CAPTCHA** — they only work from un-challenged IPs, leaning on a browser-like UA. Only archivenow copes, by driving a real browser.

- **HRDepartment/archivetoday (npm, JS)** — `index.js`. GET index, rebind host to the redirected mirror, scrape `submitid` via regex, `POST https://<mirror>/submit/` body `url=<encodeURIComponent(url)>&submitid=…` (+`anyway=1`), `redirect:'manual'`, random UA from `user-agents`. Result from **`Refresh` header** (200) or `Location` (302/307); polls `/wip/`. **Retrieve = `GET ${domain}/timemap/${url}`** with URL spliced RAW, parsed as Memento link-format. No Cloudflare handling.
- **jaytaylor/archive.today (Go)** — `capture.go`/`http.go`. `BaseURL=https://archive.today`, hardcoded Chrome 65 UA, sets `Host/Origin/Authority/Referer`. Scrape `input[name=submitid]`, `POST /submit/` body `submitid=…&url=…(&anyway=1)`. Result from 3xx `Location`, else JS `document.location.replace(...)` regex, else `input[name=id]`→`/`+id. No captcha handling.
- **palewire/archiveis (Python, pure HTTP)** — `api.py`. The classic client that broke once Cloudflare/CAPTCHA arrived. `domain=requests.get("https://archive.is").url`, `submitid` via string-split, `POST domain+"submit/"` form `{url, submitid}`, result from `Refresh`→`Location`→`history`. No anti-bot.
- **oduwsdl/archivenow (Python)** — `is_handler.py`. **Selenium + headless Firefox**: `driver.get("https://archive.is")`, type into `#url`, click submit XPath, handle the "already archived?" confirm page, poll `while 'wip' not in url and 'submit' not in url`. This is the only one that can pass the reCAPTCHA — via a real browser. Direct HTTP submission stopped working ~2020/2021 (429 + reCAPTCHA), prompting the Selenium switch (issue #53).
- **waybackpy** — Wayback Machine client, NOT archive.today; out of scope (commonly conflated).
- **Wikipedia "Help:Using archive.today"** now redirects to deprecation guidance (archive.today deprecated as a WP source over DDoS-injection/tampering). URL formats survive on the main article.

Sources: https://github.com/HRDepartment/archivetoday, https://github.com/jaytaylor/archive.today, https://github.com/palewire/archiveis, https://github.com/oduwsdl/archivenow (issue #53), ArchiveTeam wiki.

---

## (4) Memento TimeMap — is it CAPTCHA-gated?

- **TimeMap exists at `/timemap/<url>`, returns RFC 7089 link-format text** whose lines ARE directly-loadable snapshot URLs (`/<datetime>/<url>` canonical + derivable shortcodes), oldest→newest. (Confirmed from HRDepartment parser + ArchiveTeam wiki.)
- **It appears NOT to require the CAPTCHA/submitid handshake — likely.** Strong code signal: in HRDepartment's lib, `timemap()` is a bare `GET` with only a UA header and **no** captcha logic, while `snapshot()` (submit) carries all the `submitid`/captcha machinery and its TS declaration `@throws if there is a captcha`; `timemap()` has no such caveat. The documented CAPTCHA/429 wall is specifically on `/submit/` (archivenow #53).
- **BUT gating is IP/DNS-reputation-driven, not a documented path exemption.** A clean residential IP reads `/timemap/` freely; a VPN/proxy/datacenter/flagged IP can still be challenged on any path. No public evidence archive.today explicitly whitelists `/timemap/`.
- **Direct snapshot reads (`/<shortid>`, `/<datetime>/<url>`) are lighter-gated than `/submit/` or `/newest/`** — the lightest path is loading a snapshot URL you already hold (e.g. from a prior timemap).
- **The public Memento aggregator (timetravel.mementoweb.org) is DEAD** (LANL decommissioned ~5 Sep 2025) — you can no longer offload archive.today resolution to it. Self-hosting MemGator still hits archive.today's gate from your server's IP.

**Implication:** TimeMap → resolve newest snapshot URL → load that specific snapshot is the most promising low-CAPTCHA archive.today flow, but treat "no CAPTCHA" as *likely, IP-dependent*, not guaranteed.

Sources: RFC 7089 (https://www.rfc-editor.org/rfc/rfc7089.html), HRDepartment index.js, archivenow #53, https://en.wikipedia.org/wiki/Memento_Project.

---

## (5) Alternatives for WSJ/FT full text on iOS — ranked

| Rank | Approach | Clean API? | Anti-bot gated? | WSJ/FT reliability |
|---|---|---|---|---|
| 1 | **Wayback CDX + Availability API** then on-device Readability/Mercury extraction | ✅ open JSON | ❌ (soft 429 only) | **Flaky** — works when a 200 snapshot exists; FT blocks IA crawler; broad publisher blocking growing 2025–26 |
| 2 | **archive.today** (TimeMap→snapshot read) | ❌ URL-prefix/manual | ✅ reCAPTCHA + DNS/EDNS + per-IP quota | **Flaky** — best raw coverage but hostile to automation; WSJ hardening since Sep 2024; region-blocked in Russia Mar 2026 |
| 3 | **removepaywall(s).com** fallback | ❌ | inherits archive.today | **Flaky** — just proxies #1/#2; admits hard paywalls fail |
| — | Readability.js / Mercury / Postlight | ✅ self-host | ❌ | **Post-processor only** — extracts body from HTML you already have; cannot bypass |
| — | freedium.cfd | ❌ | mild | **Medium only** — N/A for WSJ/FT |
| ✗ | Google Cache | — | — | **DEAD** (Feb 2024; `webcache` now redirects) |
| ✗ | Bing Cache / cc.bingj.com | — | — | **DEAD** (Dec 2024) |
| ✗ | 12ft.io | — | — | **DEAD** (offline Jul 2025; only ever beat soft paywalls) |
| ✗ | Memento Time Travel aggregator | — | — | **DEAD** as hosted service (Sep 2025) |
| ✗ | outline.com / RSS full-text / Apple News | — | — | dead / summary-only / closed |

**Wayback API shapes:**
- Availability: `GET https://archive.org/wayback/available?url=<URL>[&timestamp=YYYYMMDD]` → JSON `archived_snapshots.closest.{url,timestamp,status}` (`{}` when none).
- CDX (better for "newest readable"): `GET https://web.archive.org/cdx/search/cdx?url=<URL>&output=json&filter=statuscode:200&collapse=digest&limit=-1`.
- Not Cloudflare-gated; throttles bulk use with 429 — set a clear UA, back off.

Reality check: FT actively blocks the IA crawler, so Wayback usually holds only free FT stories; for hard paywalls the body legitimately doesn't exist unauthenticated. The robust legal route to full WSJ/FT text is a licensed aggregator (Factiva, ProQuest) or subscriber credentials.

Sources: https://github.com/internetarchive/wayback/blob/master/wayback-cdx-server/README.md, https://www.niemanlab.org/2026/01/news-publishers-limit-internet-archive-access-due-to-ai-scraping-concerns/, https://ppc.land/google-removes-cache-feature-from-search-results/, https://searchengineland.com/bing-officially-removes-cache-link-from-search-results-449220, https://en.wikipedia.org/wiki/12ft, https://news.ycombinator.com/item?id=41693520.

---

## (6) cf_clearance binding specifics

- **Bound to IP + User-Agent + TLS/JA3 fingerprint — CONFIRMED (community/reverse-engineering consensus).** Replaying a browser-solved cookie from a different stack (e.g. Python `requests`) fails; changing IP invalidates it; a Chrome UA over a Python JA3 is itself a detectable mismatch. Cloudflare's official docs are deliberately vaguer — cookie is "securely tied to the specific visitor and device" — without naming IP/UA/JA3.
- **Zone-wide / cross-path — CONFIRMED.** A valid clearance bypasses challenges across other paths on the same registrable domain. Exception: a path with a *higher* security level forces a fresh solve. So clearance from the homepage WOULD carry to `/newest/` and the snapshot path **if** the gate were Cloudflare's — but archive.today's primary gate is DNS + its own reCAPTCHA, so this carry-over doesn't rescue you.
- **Lifetime:** Cloudflare default 30 min (configurable 15–45), +1h for XHR; "Under Attack" shortens it. archive.today's own reCAPTCHA grants only ~5 min.
- **WKWebView caveat — CONFIRMED problem.** Cloudflare human-verification (Turnstile/Managed Challenge) is widely reported to **fail inside iOS WKWebView while Safari on the same device works.** Implicated: changing the WebView `customUserAgent` mid-session breaks the challenge (must stay consistent); WebViews have restricted web APIs/storage; `about:blank`/`about:srcdoc` must be allowlisted for the challenge iframe. ITP cookie partitioning is a *plausible* contributor (it would break archive.today's cross-domain cookie hand-off) but I found no source directly attributing the WKWebView failure to ITP — treat as speculative.

Sources: https://developers.cloudflare.com/cloudflare-challenges/concepts/clearance/, https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/challenge-passage/, https://github.com/FlareSolverr/FlareSolverr (issues #871, #368), https://community.cloudflare.com/t/wkwebview-fail-to-pass-cloudflare-human-verification/610067, https://developers.cloudflare.com/turnstile/get-started/mobile-implementation/.

---

## Recommendations, ranked

1. **Stop relying on `/submit/` and the homepage warm-up.** Switch to a READ-first flow: resolve the newest snapshot via `GET https://archive.<tld>/timemap/<RAW url>` (or `/timegate/<url>`), parse the link-format, then load the specific `/<shortid>` or `/<datetime>/<url>` snapshot directly. Reads are the lightest-gated path.
2. **Pin DNS away from Cloudflare.** The single highest-leverage fix. On iOS you can't change the system resolver inside your app sandbox easily, but you CAN avoid resolver dependence by resolving archive.today through a server-side proxy you control (your Cloudflare Worker `production/api`) that queries an ECS-respecting resolver (8.8.8.8) — and ideally does the whole timemap/snapshot fetch server-side, returning clean HTML to the app. This also dodges the WKWebView Turnstile failure entirely.
3. **Keep the User-Agent stable and mainstream.** Never change WKWebView `customUserAgent` mid-session; use a current Safari/Chrome UA. UA changes break both reCAPTCHA and any cf_clearance.
4. **Add Wayback CDX as the primary clean fallback** (no CAPTCHA): query newest `statuscode:200` snapshot, fetch HTML, run on-device Readability extraction. Expect frequent WSJ/FT misses and handle them gracefully.
5. **For the in-app WKWebView path** (if kept): use a persistent cookie store, mainstream UA, allow `about:blank`, allow third-party cookies for the archive domains, and expect to surface a manual CAPTCHA to the user. The Safari Web Extension path is more robust because it runs in real Safari (system resolver, real cookies, no WKWebView restrictions) and the user solves the CAPTCHA naturally.
6. **Drop dead options entirely:** Google/Bing cache, 12ft.io, Memento aggregator.

### Confidence ledger
- Confirmed: endpoint set & raw encoding; submit/`submitid`/`Refresh` mechanics; DNS/EDNS root cause + 8.8.8.8 fix; library implementations; cf_clearance IP+UA+JA3 binding & zone-wide scope; WKWebView Turnstile failures; deaths of Google/Bing cache, 12ft, Memento aggregator.
- Likely (code-evidenced, not first-hand): `/timemap/` and direct snapshot reads not requiring the CAPTCHA handshake; `/newest/` 302→shortid; `id_` raw variant path.
- Refuted: homepage warm-up as a general cure for the loop (no evidence; wrong layer).
- Speculative: ITP cookie partitioning as the specific cause of WKWebView Turnstile failure.
