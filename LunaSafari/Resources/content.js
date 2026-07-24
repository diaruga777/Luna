// Luna Safari content script. Injects a Luna button on article pages (per the
// app's visibility setting), known Downloader-platform pages, or recognized
// product pages — but ONLY for the page kinds this extension's containing app
// handles (the native handler's supportsArticles/Media/Products flags). A tap
// always deep-links into the containing app via its own scheme.

(function () {
    "use strict";

    // The background script injects this via scripting.executeScript, which can
    // fire more than once per document — run our setup only the first time.
    if (window.__queueContentScriptRan) { return; }
    window.__queueContentScriptRan = true;

    var QUEUE_INDIGO = "#5856D6";
    // Generated from ProductPageRules.swift and injected immediately before this
    // script. No local fallback is intentional: a missing artifact must not silently
    // resurrect an independently-maintained Safari rule set.
    var PRODUCT_RULES = self.__LUNA_PRODUCT_RULES || {};

    function productRuleArray(name) {
        return Array.isArray(PRODUCT_RULES[name]) ? PRODUCT_RULES[name] : [];
    }

    // Mirrors PaywallDetector.gateMarkers (Swift) — keep in sync. Gate phrases only
    // appear when an article body is cut off behind a subscription wall.
    var GATE_MARKERS = [
        "to continue reading", "continue reading this article", "continue reading with",
        "login or signup to continue", "log in or sign up to continue",
        "sign in to continue reading", "log in to continue reading",
        "subscribe to continue", "subscribe to read", "register to continue",
        "sign up to continue reading", "subscribe now for unlimited",
        "subscribe for unlimited access", "this article is for subscribers",
        "this story is for subscribers", "this content is for subscribers",
        "available to subscribers", "subscribers only", "subscriber exclusive",
        "to read the full article", "to read the full story", "for full access",
        "already a subscriber? log in", "already a subscriber? sign in",
        "unlock this article", "this article is reserved for subscribers"
    ];

    // Guards every top-level extension-runtime entry point so this file can also
    // be loaded (for its heuristics) in a bare WKWebView with no `browser` global,
    // e.g. from an XCTest — see `window.__lunaLooksLikeArticle` below.
    if (typeof browser !== "undefined") {
        browser.runtime.sendMessage({ type: "buttonContext" }).then(function (resp) {
            var mode = (resp && resp.mode) || "all";
            if (mode === "never") { return; }
            var platform = recognizedPlatformPage();
            // Reddit is media-gated and SPA-aware; its own handler owns injection,
            // the retry-on-hydration schedule, and the soft-nav watcher.
            if (platform === "reddit") { handleReddit(resp); return; }
            if (platform) {
                if (!shouldShowDownloadPillForPlatform(platform)) { return; }
                var downloadTarget = downloadTargetFor(resp);
                if (downloadTarget) { injectLunaButton(downloadTarget); }
                return;
            }
            // Reddit feed / listing / comment-history pages are NOT posts: suppress
            // the product/article heuristics entirely (a feed must never get any
            // pill) while keeping the SPA watcher live so a soft-nav INTO a post
            // still gains the pill.
            if (isRedditHost()) { handleReddit(resp); return; }
            // Product pages win over the fallback article heuristics (a retail page's
            // long description can read as an article body). Deterministic known-news
            // hosts remain articles, matching Swift's Classifier/IngestPipeline:
            // publisher store cards and subscription components must not turn the
            // primary article into a Price Tracker hand-off.
            if (looksLikeProductPage()) {
                var trackTarget = trackTargetFor(resp);
                if (trackTarget) { injectLunaButton(trackTarget); }
                return;
            }
            if (!isArticlePage()) {
                // Some article bodies hydrate late (SPA/client-rendered pages) --
                // give the DOM a chance to settle, then re-check once. (A known
                // article host classifies immediately, so it never reaches here.)
                setTimeout(function () { tryInjectArticleButton(mode, resp); }, 2500);
                return;
            }
            if (mode === "onlyLocked" && !pageIsLocked()) { return; }
            var target = readTarget(resp);
            if (target) { injectLunaButton(target); }
        }).catch(function () {});

        // Reveal the article body in Safari (the Referer rewrite that unlocks the
        // server response is applied declaratively by the background ruleset; this
        // strips the leftover overlay/clamp so the reader — and the user, right
        // here in Safari — sees the full article). The native handler answers
        // `enabled` only for article-handling hosts (Reader and the central Luna
        // app) — unlocking is article handling, so the Downloader and Price
        // Tracker extensions never reveal.
        browser.runtime.sendMessage({ type: "bypassEnabled" }).then(function (resp) {
            if (resp && resp.enabled) { revealArticle(); }
        }).catch(function () {});
    }

    // One-shot re-check of just the article branch (mirrors the tail of the
    // `buttonContext` handler above) for the 2500ms SPA retry.
    function tryInjectArticleButton(mode, resp) {
        if (!isArticlePage()) { return; }
        if (mode === "onlyLocked" && !pageIsLocked()) { return; }
        var target = readTarget(resp);
        if (target) { injectLunaButton(target); }
    }

    // Generic paywall-overlay cleanup (mirrors the app's browser-tier cleanup): remove
    // common overlay containers, un-blur/un-clamp the body, restore scroll, un-lazy
    // images. Re-runs briefly to cover late hydration.
    function revealArticle() {
        // Toast once per page, and ONLY when the cleanup actually removed or revealed a
        // recognized paywall overlay node (announced from inside `clean()`). Detecting a
        // paywall MARKER is NOT enough: many sites (e.g. New Statesman) serve the full
        // body behind a client-side registration nag whose container we don't remove and
        // don't need to — there's nothing to unlock, so claiming "Unlocked with Luna"
        // there is dishonest. (The UNHIDE class sweep also doesn't count — names like
        // "fade" are common on unrelated elements.)
        var announced = false;
        function announceUnlock() {
            if (announced) { return; }
            announced = true;
            showUnlockToast();
        }
        var REMOVE = [
            "div.paywall", "div.paywall-content", "div.meteredContent", "div#full-paywall",
            "aside#paywall", "div.subscription-wall", "div#tp-regwall", "div#tp-modal",
            "div.snippet-promotion", ".snippet-promotion", 'div[id*="-snippet-overlay"]',
            "div.modal-backdrop", 'div[class*="subscribe-wall"]', 'div[class*="regwall"]',
            "div.tp-modal", 'div[data-testid*="paywall"]', 'div[class*="PaywallOverlay"]',
            "div.piano-template",
            // Generic, structure/attribute-driven paywall containers (no site names).
            // A metering wall is commonly a component-declared node plus a backdrop and
            // an "inline backup" wall, with the article gated behind them — Business
            // Insider ships exactly this (`pw-modal-backdrop`, a `data-component-type`
            // paywall component, an `inline-backup-paywall`), and it is a very common
            // shape. The `articleChars` guard below reveals (never deletes) any of these
            // that actually holds the story, so a broad match here is safe.
            '[data-component-type*="paywall" i]',
            'div[class*="pw-modal"]',
            '[class*="paywall-backdrop"]', '[class*="paywall-overlay"]',
            '[class*="paywall-modal"]', '[class*="paywall-container"]',
            '[class*="registration-wall"]', '[class*="regi-wall"]', '[class*="reg-wall"]',
            '[class*="metering-overlay"]', '[id*="paywall"]'
        ];
        var UNHIDE = ["blurred", "blur", "gradient", "fade", "faded-content", "clipped",
            "cropped", "truncated", "locked", "is-locked", "noscroll", "no-scroll",
            "scroll-lock", "overflow-hidden", "modal-open"];
        // `paywall` is also used as the visibility class on full article paragraphs
        // (New Yorker/Condé Nast). Only strip it when this is actually an article;
        // bypass being enabled must not reveal similarly-named account/checkout UI.
        if (isArticlePage()) { UNHIDE.unshift("paywall"); }
        // Substantial article prose inside an element (>= 2 paragraphs over 60
        // chars); 0 when it holds none. Distinguishes a content wrapper from an
        // overlay/promo that happens to share a paywall class.
        function articleChars(el) {
            var ps = el.querySelectorAll("p"), c = 0, n = 0;
            for (var i = 0; i < ps.length; i++) {
                var t = (ps[i].textContent || "").trim().length;
                if (t > 60) { n++; c += t; }
            }
            return n >= 2 ? c : 0;
        }
        // Safe to DELETE only if it can't be the article shell: a positioned layer
        // (fixed/absolute/sticky overlay/backdrop) or a small, near-empty node. A large
        // in-flow block is revealed, never removed, so cleanup can't blank the page.
        function isDeletableOverlay(el) {
            var text = ((el.innerText || "").trim()).length;
            if (text < 400) { return true; }
            try {
                var pos = window.getComputedStyle(el).position;
                return pos === "fixed" || pos === "absolute" || pos === "sticky";
            } catch (e) { return false; }
        }
        function reveal(el) {
            el.style.removeProperty("display");
            el.style.visibility = "visible"; el.style.opacity = "1";
            el.style.maxHeight = "none"; el.style.height = "auto";
            el.style.overflow = "visible"; el.style.filter = "none"; el.style.webkitMaskImage = "none";
            UNHIDE.forEach(function (c) { if (el.classList) { el.classList.remove(c); } });
        }
        function clean() {
            try {
                REMOVE.forEach(function (sel) {
                    document.querySelectorAll(sel).forEach(function (el) {
                        // Some sites deliver the UNLOCKED article inside the same node
                        // the paywall class names (e.g. a `.paywall` content container).
                        // Deleting it would take the story with it — so reveal a node
                        // holding real prose, and only remove a content-LESS overlay.
                        // Belt-and-braces: never DELETE a large in-flow region either
                        // (a broad selector could match a structural shell the site
                        // re-gates after load) — reveal it instead. Only a positioned
                        // layer or a small/near-empty node is safe to remove. This is
                        // what stops the cleanup from ever blanking a page.
                        if (articleChars(el) > 400) { reveal(el); }
                        else if (isDeletableOverlay(el)) { el.remove(); }
                        else { reveal(el); }
                        announceUnlock();
                    });
                });
                [document.documentElement, document.body].forEach(function (el) {
                    if (!el) { return; }
                    el.style.overflow = ""; el.style.position = ""; el.style.height = "";
                    UNHIDE.forEach(function (c) { if (el.classList) { el.classList.remove(c); } });
                });
                if (document.documentElement) { document.documentElement.style.overflow = "auto"; }
                UNHIDE.forEach(function (c) {
                    document.querySelectorAll("." + c).forEach(function (el) {
                        el.classList.remove(c);
                        el.style.filter = "none"; el.style.webkitFilter = "none";
                        el.style.maxHeight = "none"; el.style.overflow = "visible";
                        el.style.webkitMaskImage = "none";
                    });
                });
                // Un-clamp any element that STILL holds substantial article prose but is
                // being height-limited / masked / blurred inline — the teaser clamp a
                // metered wall applies to its content container when it doesn't use one of
                // the UNHIDE class names above. Prose-guarded (>= 2 real paragraphs), so
                // ordinary UI clamps ("show more" teasers, cards) are left alone; it does
                // NOT announce an unlock on its own, since a benign clamp is not a paywall.
                document.querySelectorAll("[style]").forEach(function (el) {
                    var s = (el.getAttribute("style") || "").toLowerCase();
                    var clamped = s.indexOf("max-height") >= 0 || s.indexOf("mask-image") >= 0
                        || s.indexOf("-webkit-mask") >= 0
                        || /overflow\s*:\s*hidden/.test(s) || /filter\s*:\s*blur/.test(s);
                    if (clamped && articleChars(el) > 400) { reveal(el); }
                });
            } catch (e) {}
        }
        clean();
        var n = 0;
        var t = setInterval(function () { clean(); if (++n > 10) { clearInterval(t); } }, 600);
    }

    // A brief "Unlocked with Luna" capsule, centered above the corner where the
    // "Read in Luna" button sits so the two can never overlap. Fades out and
    // removes itself after a few seconds.
    function showUnlockToast() {
        if (document.getElementById("queue-unlock-toast")) { return; }
        var toast = document.createElement("div");
        toast.id = "queue-unlock-toast";
        toast.appendChild(document.createTextNode("Unlocked with Luna"));
        applyStyle(toast, {
            position: "fixed", left: "50%",
            // The button pill is ~48px tall at bottom 20px; 84px clears it plus a gap.
            bottom: "calc(84px + env(safe-area-inset-bottom))",
            transform: "translateX(-50%)",
            zIndex: "2147483647", background: QUEUE_INDIGO, color: "#ffffff",
            font: "600 15px/1 -apple-system, system-ui, sans-serif",
            boxSizing: "border-box", display: "inline-flex",
            alignItems: "center", justifyContent: "center", whiteSpace: "nowrap",
            border: "none", borderRadius: "999px", padding: "12px 20px",
            height: "auto", minHeight: "0", width: "auto", margin: "0",
            boxShadow: "0 6px 20px rgba(0,0,0,0.30)", pointerEvents: "none",
            opacity: "0", transition: "opacity 0.3s ease"
        });
        (document.body || document.documentElement).appendChild(toast);
        requestAnimationFrame(function () { toast.style.opacity = "1"; });
        setTimeout(function () {
            toast.style.opacity = "0";
            setTimeout(function () {
                if (toast.parentNode) { toast.parentNode.removeChild(toast); }
            }, 400);
        }, 3000);
    }

    // Test hook for the bare-WKWebView harness. The production path invokes the same
    // function only after the native handler confirms on-device bypass is enabled.
    window.__lunaRevealArticle = revealArticle;

    // A page worth a "Read in Luna" button: article/blog/essay/book prose, not a
    // landing page, comment thread, docs/reference page, listing, or login gate.
    // A lightweight Readability-style scorer: hard negatives are checked first
    // (teaser feed, link-heavy page, docs URL/code-heavy page, login gate); the
    // surviving candidate paragraph-like nodes are filtered (list items, hidden
    // nodes, high own-link-density, "unlikely" container ancestry) and scored by
    // sqrt(length); metadata (og:type, JSON-LD Article/BlogPosting, byline+date,
    // or a single dominant <article>) lowers the score bar. This scorer is the
    // FALLBACK for hosts not on the shared news-host list: the app recognizes known
    // news/article sites by URL host alone (see `isKnownArticleHost`), and only such
    // unknown hosts reach this DOM heuristic. On save the app re-classifies properly
    // via LunaIngest.
    function looksLikeArticle() {
        var body = document.body;
        if (!body) { return false; }
        if (document.querySelectorAll("article").length >= 4) { return false; }
        if (wholePageLinkDensity(body) > 0.5) { return false; }
        if (isDocPathURL()) { return false; }
        if (document.querySelector('input[type="password"]')) { return false; }

        var candidates = collectArticleCandidates();
        var score = 0;
        var totalQualifyingText = 0;
        var parentTotals = new Map();
        var qualifying = [];
        for (var i = 0; i < candidates.length; i++) {
            var node = candidates[i];
            var len = (node.innerText || "").length;
            if (len < 140) { continue; }
            score += Math.sqrt(len - 140);
            totalQualifyingText += len;
            qualifying.push({ node: node, len: len });
            var parent = node.parentElement;
            if (parent) { parentTotals.set(parent, (parentTotals.get(parent) || 0) + len); }
        }

        // Documentation (continued from the URL check above): a page dominated by
        // code samples rather than qualifying prose.
        var codeLength = 0;
        var codeEls = document.querySelectorAll("pre, code");
        for (var c = 0; c < codeEls.length; c++) { codeLength += (codeEls[c].innerText || "").length; }
        if (codeLength > totalQualifyingText) { return false; }

        var largestClusterShare = 0;
        if (totalQualifyingText > 0) {
            var maxParentTotal = 0;
            parentTotals.forEach(function (total) { if (total > maxParentTotal) { maxParentTotal = total; } });
            largestClusterShare = maxParentTotal / totalQualifyingText;
        }

        if (hasStrongArticleEvidence(qualifying, totalQualifyingText)) { return score > 20; }
        return score > 40 && largestClusterShare >= 0.5;
    }

    // Exposed so tests can load this file into a bare WKWebView (no `browser`
    // global) and exercise the heuristic directly.
    window.__lunaLooksLikeArticle = looksLikeArticle;

    // Reddit gating hooks, exposed for the same bare-WKWebView test harness.
    // `__lunaRedditPostID` parses a URL STRING (so URL gating doesn't depend on the
    // harness propagating baseURL to `location`); the media/platform hooks read the
    // loaded document.
    window.__lunaRedditPostID = function (urlString) {
        try {
            var u = new URL(urlString);
            var host = (u.hostname || "").toLowerCase();
            var segments = u.pathname.split("/").filter(function (s) { return s.length > 0; });
            if (host === "redd.it") { return nonEmptySegment(segments[0]); }
            return redditPostID(segments);
        } catch (e) { return null; }
    };
    window.__lunaRedditPostHasMedia = redditPostHasMedia;
    window.__lunaRecognizedPlatformPage = recognizedPlatformPage;
    window.__lunaShouldShowDownloadPillForPlatform = shouldShowDownloadPillForPlatform;

    // The app recognizes news/article sites by URL host (NewsSites.hardPaywall / .free
    // in LunaURLClassification, via KnownSite.matches' host-suffix test). The Safari
    // extension shares that exact host data through the generated
    // `news_hosts.generated.js` (injected before this file by background.js; guarded
    // against drift by NewsSitesJSParityTests), so a known article host can still rescue
    // a metered page whose rendered teaser is too thin for the prose scorer. Host
    // recognition is deliberately a FALLBACK, however: a publisher homepage / section
    // index is on the same host and must never gain a reader pill just for that reason.
    function knownNewsHosts(key) {
        var data = (typeof self !== "undefined") ? self.__LUNA_NEWS_HOSTS : undefined;
        return (data && data[key]) || [];
    }
    function isKnownArticleHost() {
        var host = (location.hostname || "").toLowerCase();
        return hostMatches(host, knownNewsHosts("hardPaywall"))
            || hostMatches(host, knownNewsHosts("free"));
    }
    function isKnownHardPaywallHost() {
        var host = (location.hostname || "").toLowerCase();
        return hostMatches(host, knownNewsHosts("hardPaywall"));
    }
    // "Locked" for the onlyLocked suggestion mode: the app would know this is paywalled
    // by host (a hard-paywall news site) OR the page carries paywall markers. Note
    // `looksPaywalled` itself is left untouched -- it also drives the "Unlocked with
    // Luna" toast, which must stay honest to actual on-page markers.
    function pageIsLocked() {
        return isKnownHardPaywallHost() || looksPaywalled();
    }

    // Combined article verdict, exposed for the bare-WKWebView test harness.
    //
    // A known news host mirrors the app's `NewsSites.free`/`.hardPaywall` fast-path,
    // which classifies the host as `.article` OUTRIGHT with zero DOM inspection. The
    // Safari side must not be strictly weaker: a real article routinely embeds a
    // "read next" rail of related-story `<article>` cards (Business Insider ships six
    // `<article>` elements) and becomes link-dense once its body is metered, which
    // trips the structural index heuristics (`>= 4 <article>`, whole-page link
    // density). Those were meant to reject a publisher FRONT/section page, not to
    // override a known host — so on a known host, POSITIVE article metadata
    // (og:type=article, or an Article/NewsArticle/BlogPosting JSON-LD node) decides
    // "article" and the structural veto no longer applies. Only a page that carries
    // NO article declaration at all falls back to the full index veto, so a
    // publisher homepage on the same host still gets no pill.
    //
    // Unknown hosts are unchanged: an obvious index vetoes, then the prose scorer
    // decides. On save the app re-classifies properly via LunaIngest either way.
    function isArticlePage() {
        if (isKnownArticleHost()) {
            if (pageDeclaresArticle()) { return true; }
            return !looksLikeNonArticleIndex();
        }
        if (looksLikeNonArticleIndex()) { return false; }
        return looksLikeArticle();
    }

    // Explicit "this is an article" markup, independent of how much prose has
    // rendered (so a thin metered teaser on a known host still qualifies). Reuses
    // the same signals the prose scorer treats as strong evidence.
    function pageDeclaresArticle() {
        var ogType = document.querySelector('meta[property="og:type"]');
        if (ogType && /article/i.test(ogType.getAttribute("content") || "")) { return true; }
        return hasArticleJSONLD();
    }
    window.__lunaIsArticlePage = isArticlePage;
    window.__lunaPageDeclaresArticle = pageDeclaresArticle;
    window.__lunaIsKnownHardPaywallHost = isKnownHardPaywallHost;

    // An index is not something Luna can read as one article, even when its publisher
    // is in the known-news host list. These are intentionally structural signals rather
    // than site names:
    //   * repeated <article>s or a link-dense page are universal listing shapes;
    //   * a page declaring itself as a landing / collection / search / site page AND
    //     exposing a cluster of headline-sized links is a publisher front/section page.
    // Requiring both metadata and the visible link cluster for the latter avoids
    // rejecting a genuine article merely because it also declares generic WebPage data.
    function looksLikeNonArticleIndex() {
        var body = document.body;
        if (!body) { return false; }
        if (document.querySelectorAll("article").length >= 4) { return true; }
        if (wholePageLinkDensity(body) > 0.5) { return true; }
        return declaresListingPage() && headlineLinkCount() >= 5;
    }

    function declaresListingPage() {
        var scripts = document.querySelectorAll('script[type="application/ld+json"]');
        var combined = "";
        for (var i = 0; i < scripts.length; i++) { combined += " " + (scripts[i].textContent || "").toLowerCase(); }
        // `landing_homepage` is used by CNN and similar publisher fronts. The schema
        // types cover category, search, and site indexes without assigning meaning to a
        // generic WebPage declaration, which many real articles legitimately include.
        if (/landing[ _-]?(home)?page|front[ _-]?page/.test(combined)) { return true; }
        return /"@type"\s*:\s*"(?:collectionpage|searchresultspage|itemlist|website)"/.test(combined)
            || /"@type"\s*:\s*\[[^\]]*"(?:collectionpage|searchresultspage|itemlist|website)"/.test(combined);
    }

    // Counts distinct, substantial destination links outside chrome. A story-card grid
    // normally has many of these; article pages may have a related-links rail, but not
    // enough to combine with the explicit listing metadata above.
    function headlineLinkCount() {
        var links = document.querySelectorAll("a[href]");
        var destinations = Object.create(null);
        var count = 0;
        for (var i = 0; i < links.length; i++) {
            var link = links[i];
            if (headlineLinkIsChrome(link)) { continue; }
            var text = (link.innerText || "").replace(/\s+/g, " ").trim();
            if (text.length < 25) { continue; }
            var href = (link.getAttribute("href") || "").trim();
            if (!href || href.charAt(0) === "#" || /^(javascript:|mailto:|tel:)/i.test(href)) { continue; }
            if (destinations[href]) { continue; }
            destinations[href] = true;
            count += 1;
            if (count >= 5) { return count; }
        }
        return count;
    }

    // Story cards are intentionally counted above, so this cannot reuse
    // `ancestorDisqualifies` (which quite correctly rejects `.card` for prose
    // extraction). For a headline link we only exclude actual site chrome.
    function headlineLinkIsChrome(node) {
        var current = node;
        for (var depth = 0; current && depth <= 5; depth++) {
            var tag = (current.tagName || "").toLowerCase();
            if (tag === "nav" || tag === "header" || tag === "footer") { return true; }
            var className = typeof current.className === "string" ? current.className : "";
            var combined = (className + " " + (current.id || "")).trim();
            if (/(nav|menu|footer|header|breadcrumb|pagination|cookie|account|social|share)/i.test(combined)
                && !/(article|body|content|main|story|post|entry)/i.test(combined)) {
                return true;
            }
            if (current === document.body) { break; }
            current = current.parentElement;
        }
        return false;
    }

    // Sum of `<a>` innerText inside `root`, divided by `root`'s own innerText
    // length -- a whole-page link density above 0.5 flags a listing/nav-heavy page.
    function wholePageLinkDensity(root) {
        var totalText = (root.innerText || "").length;
        if (totalText === 0) { return 0; }
        var anchors = root.querySelectorAll("a");
        var linkText = 0;
        for (var i = 0; i < anchors.length; i++) { linkText += (anchors[i].innerText || "").length; }
        return linkText / totalText;
    }

    var DOC_URL_SEGMENTS = ["docs", "documentation", "api", "reference", "sdk", "changelog"];

    // The first or second URL path segment names a documentation section.
    function isDocPathURL() {
        var segments = location.pathname.split("/").filter(function (s) { return s.length > 0; });
        for (var i = 0; i < 2 && i < segments.length; i++) {
            if (DOC_URL_SEGMENTS.indexOf(segments[i].toLowerCase()) >= 0) { return true; }
        }
        return false;
    }

    // <p> elements, plus the deduped parent of each `div > br` pattern (old-school
    // / book-style pages formatted with <br> instead of <p>) -- never a <pre> --
    // filtered for list-item nesting, hidden nodes, high own-link-density, and
    // "unlikely" container ancestry.
    function collectArticleCandidates() {
        var raw = [];
        var paragraphs = document.querySelectorAll("p");
        for (var i = 0; i < paragraphs.length; i++) { raw.push(paragraphs[i]); }
        var brs = document.querySelectorAll("div > br");
        var seenDivs = [];
        for (var b = 0; b < brs.length; b++) {
            var div = brs[b].parentElement;
            if (div && seenDivs.indexOf(div) < 0) {
                seenDivs.push(div);
                raw.push(div);
            }
        }
        var result = [];
        for (var j = 0; j < raw.length; j++) {
            if (!isSkippableCandidate(raw[j])) { result.push(raw[j]); }
        }
        return result;
    }

    function isSkippableCandidate(node) {
        // Nested inside a list item (the `li p` selector only ever matches <p>).
        if (typeof node.matches === "function" && node.matches("li p")) { return true; }
        if (isHiddenCandidate(node)) { return true; }
        var text = node.innerText || "";
        if (text.length > 0) {
            var linkText = 0;
            var anchors = node.querySelectorAll("a");
            for (var i = 0; i < anchors.length; i++) { linkText += (anchors[i].innerText || "").length; }
            if (linkText / text.length > 0.2) { return true; }
        }
        return ancestorDisqualifies(node);
    }

    // Cheap hidden checks only (inline style / attributes) -- no getComputedStyle.
    function isHiddenCandidate(node) {
        if (node.hidden) { return true; }
        if (node.getAttribute && node.getAttribute("aria-hidden") === "true") { return true; }
        if (node.style && (node.style.display === "none" || node.style.visibility === "hidden")) { return true; }
        return false;
    }

    // UNLIKELY container names (comment threads, chrome, promo/social rails, …)
    // unless the same class/id string also reads as the POSITIVE main-content case.
    var ARTICLE_UNLIKELY_RE = /comment|disqus|replies|sidebar|footer|header|nav|menu|banner|related|promo|newsletter|social|share|card|carousel|hero|breadcrumb|pagination|popup|cookie|subscribe|testimonial|pricing|footnote/i;
    var ARTICLE_POSITIVE_RE = /article|body|content|main|story|post|entry|prose|text/i;

    // The node or any of its nearest 5 ancestors (stopping at <body>) has an
    // UNLIKELY class/id without a POSITIVE one -- checked per-ancestor, so a
    // POSITIVE great-grandparent doesn't rescue an UNLIKELY direct parent.
    function ancestorDisqualifies(node) {
        var current = node;
        for (var depth = 0; current && depth <= 5; depth++) {
            if (classIdDisqualifies(current)) { return true; }
            if (current === document.body) { break; }
            current = current.parentElement;
        }
        return false;
    }

    function classIdDisqualifies(el) {
        // `className` isn't a string on SVG elements (SVGAnimatedString there).
        var className = typeof el.className === "string" ? el.className : "";
        var combined = (className + " " + (el.id || "")).trim();
        if (!combined) { return false; }
        return ARTICLE_UNLIKELY_RE.test(combined) && !ARTICLE_POSITIVE_RE.test(combined);
    }

    // Metadata that lowers the score bar to 20 (from 40 + a cluster-concentration
    // requirement): og:type=article, a JSON-LD Article/BlogPosting node, a byline
    // + dateline pair, or a single <article> that already holds most of the
    // qualifying text.
    function hasStrongArticleEvidence(qualifying, totalQualifyingText) {
        var ogType = document.querySelector('meta[property="og:type"]');
        if (ogType && /article/i.test(ogType.getAttribute("content") || "")) { return true; }
        if (hasArticleJSONLD()) { return true; }
        if (document.querySelector('meta[name="author"], [rel="author"]') && document.querySelector("time[datetime]")) {
            return true;
        }
        var articles = document.querySelectorAll("article");
        if (articles.length === 1 && totalQualifyingText > 0) {
            var inArticle = 0;
            for (var i = 0; i < qualifying.length; i++) {
                if (articles[0].contains(qualifying[i].node)) { inArticle += qualifying[i].len; }
            }
            if (inArticle / totalQualifyingText >= 0.6) { return true; }
        }
        return false;
    }

    function hasArticleJSONLD() {
        var scripts = document.querySelectorAll('script[type="application/ld+json"]');
        for (var i = 0; i < scripts.length; i++) {
            if (/"@type"\s*:\s*"[^"]*(Article|BlogPosting)/.test(scripts[i].textContent || "")) { return true; }
        }
        return false;
    }

    // Mirrors PaywallDetector: schema.org isAccessibleForFree / content_tier, plus
    // the gate markers in the visible text.
    function looksPaywalled() {
        var compact = (document.documentElement.innerHTML || "").toLowerCase().replace(/\s+/g, "");
        if (compact.indexOf('"isaccessibleforfree":false') >= 0) { return true; }
        // content_tier value matched IN the meta tag (not a whole-doc scan).
        var tiers = ["locked", "metered", "premium"];
        for (var t = 0; t < tiers.length; t++) {
            if (compact.indexOf('content_tier"content="' + tiers[t]) >= 0
                || compact.indexOf('content-tier"content="' + tiers[t]) >= 0
                || compact.indexOf('content="' + tiers[t] + '"property="article:content_tier') >= 0) {
                return true;
            }
        }
        var text = (document.body ? document.body.innerText : "").toLowerCase();
        for (var i = 0; i < GATE_MARKERS.length; i++) {
            if (text.indexOf(GATE_MARKERS[i]) >= 0) { return true; }
        }
        return false;
    }

    // Uses ProductPageDetector's generated rule data. Only fires for a SINGLE
    // primary product (a related/recommended rail is fine); never on a search /
    // category grid showing several products at equal primacy.
    //   • A search/browse/category/deals URL is a multi-product listing — vetoed up
    //     front, whatever per-card furniture it carries (the Amazon `/s?k=…` bug).
    //   • Tier 1: structured price markup (a JSON-LD Product offer, OpenGraph product
    //     meta, or a microdata price) is decisive on its own.
    //   • Tier 2: ≥2 combinable retail signals (og:type=product, add-to-cart
    //     affordance, rating, retail URL shape) catch a single product page with no
    //     Tier-1 markup. The listing-URL veto already excludes multi-product grids,
    //     so these signals stay a standalone product classifier.
    // The Swift detector's embedded-app-state-JSON price signal is skipped here; this
    // only decides button visibility, and the app re-classifies properly on save.
    function looksLikeProductPage() {
        // Keep Safari in lockstep with Swift: a deterministic news-host match owns
        // classification before fuzzy/structured product signals. Publisher pages
        // commonly embed priced subscription offers, store cards, ratings, and
        // commerce component state that are secondary to the article itself.
        if (isKnownArticleHost()) { return false; }
        if (urlIsMultiProductListing()) { return false; }
        if (hasJSONLDProductOffer()) { return true; }
        if (parsePriceNumber(metaContent(productRuleArray("productPriceMetaNames"))) !== null) {
            return true;
        }
        if (hasMicrodataPrice()) { return true; }
        var score = 0;
        var minimumScore = PRODUCT_RULES.minimumHeuristicScore || Number.MAX_SAFE_INTEGER;
        var ogType = metaContent(["og:type"]).toLowerCase();
        if (productRuleArray("productOpenGraphTypes").indexOf(ogType) >= 0) { score += 1; }
        if (urlLooksLikeProduct()) { score += 1; }
        if (score < minimumScore && hasAddToCartAffordance()) { score += 1; }
        if (score < minimumScore && hasRatingSignal()) { score += 1; }
        return score >= minimumScore;
    }

    // Exposed so the bare-WKWebView test harness can exercise product gating directly.
    window.__lunaLooksLikeProductPage = looksLikeProductPage;

    // Uses ProductPageRules' generated listing URL data.
    // URL shapes that list many products at equal primacy (search results, browse /
    // category nodes, best-seller and deals grids). A single primary product never
    // lives at such a URL, so it is never a product page whatever per-card furniture
    // it shows.
    function urlIsMultiProductListing() {
        // A recognized single-product URL wins over a stray listing token.
        if (urlLooksLikeProduct()) { return false; }
        var segments = (location.pathname || "").split("/")
            .filter(function (s) { return s.length > 0; })
            .map(function (s) { return s.toLowerCase(); });
        // Search / browse / category / deals path segments (Amazon `/s`, `/b`; eBay
        // `/sch`; generic `/search`, `/category`, `/collections`, …).
        var listing = productRuleArray("listingFirstPathSegments");
        if (segments.length > 0 && listing.indexOf(segments[0]) >= 0) { return true; }
        var firstTwo = segments.slice(0, 2).join("/");
        if (productRuleArray("listingTwoSegmentPaths").indexOf(firstTwo) >= 0) {
            return true;
        }
        // A search query parameter (`?k=`/`?field-keywords=` Amazon, `?q=`/`?query=`/…).
        var searchParams = productRuleArray("searchQueryParameterNames");
        try {
            var params = new URLSearchParams(location.search || "");
            var iter = params.keys();
            for (var next = iter.next(); !next.done; next = iter.next()) {
                if (searchParams.indexOf((next.value || "").toLowerCase()) >= 0) { return true; }
            }
        } catch (e) {}
        return false;
    }

    function hasJSONLDProductOffer() {
        var scripts = document.querySelectorAll('script[type="application/ld+json"]');
        for (var i = 0; i < scripts.length; i++) {
            var parsed;
            try { parsed = JSON.parse(scripts[i].textContent || ""); } catch (e) { continue; }
            if (findProductNodeWithPrice(parsed)) { return true; }
        }
        return false;
    }

    // Recursively finds a JSON-LD node whose @type is (or includes) Product and
    // that carries an offer price — recursing @graph / arrays / nested objects
    // like the Swift walk.
    function findProductNodeWithPrice(node) {
        if (!node || typeof node !== "object") { return false; }
        if (Array.isArray(node)) {
            for (var i = 0; i < node.length; i++) {
                if (findProductNodeWithPrice(node[i])) { return true; }
            }
            return false;
        }
        if (typeContainsProduct(node["@type"]) && offerPrice(node) !== null) { return true; }
        for (var key in node) {
            if (Object.prototype.hasOwnProperty.call(node, key) && findProductNodeWithPrice(node[key])) {
                return true;
            }
        }
        return false;
    }

    function typeContainsProduct(type) {
        if (typeof type === "string") { return type.toLowerCase() === "product"; }
        if (Array.isArray(type)) {
            for (var i = 0; i < type.length; i++) {
                if (typeof type[i] === "string" && type[i].toLowerCase() === "product") { return true; }
            }
        }
        return false;
    }

    // The price on a Product node's offer — `offers` may be a single object, an
    // array, or an AggregateOffer wrapping `offers`/`lowPrice`; some feeds put
    // `price` directly on the product node.
    function offerPrice(node) {
        var offers = node.offers;
        var candidates = [];
        if (!offers) {
            candidates = [node];
        } else if (Array.isArray(offers)) {
            candidates = offers;
        } else if (typeof offers === "object") {
            if (offers.offers) {
                candidates = Array.isArray(offers.offers) ? offers.offers.slice() : [offers.offers];
            }
            candidates.push(offers);
        }
        for (var i = 0; i < candidates.length; i++) {
            var offer = candidates[i];
            if (!offer || typeof offer !== "object") { continue; }
            var raw = offer.price !== undefined ? offer.price : offer.lowPrice;
            if (raw === undefined && offer.priceSpecification && typeof offer.priceSpecification === "object") {
                raw = offer.priceSpecification.price;
            }
            var amount = parsePriceNumber(raw);
            if (amount !== null && amount >= 0) { return amount; }
        }
        return null;
    }

    function hasMicrodataPrice() {
        var el = document.querySelector('[itemprop="price"]');
        if (!el) { return false; }
        var amount = parsePriceNumber(el.getAttribute("content") || el.textContent || "");
        return amount !== null && amount >= 0;
    }

    // Crude numeric parse (symbols/separators stripped) — only a yes/no product
    // signal here, never a displayed or stored price.
    function parsePriceNumber(raw) {
        if (typeof raw === "number") { return isFinite(raw) ? raw : null; }
        if (typeof raw !== "string") { return null; }
        var digits = raw.replace(/[^0-9.,]/g, "").replace(/,/g, "");
        if (!digits) { return null; }
        var value = parseFloat(digits);
        return isNaN(value) ? null : value;
    }

    function hasAddToCartAffordance() {
        var els = document.querySelectorAll('button, a, [role="button"], input[type="submit"]');
        for (var i = 0; i < els.length; i++) {
            var text = ((els[i].textContent || "") + " " + (els[i].getAttribute("value") || "")).toLowerCase();
            var phrases = productRuleArray("addToCartPhrases");
            for (var phraseIndex = 0; phraseIndex < phrases.length; phraseIndex++) {
                if (text.indexOf(phrases[phraseIndex]) >= 0) { return true; }
            }
        }
        // SPA handlers (`onClick={addToCart}`, `data-testid="addToCart"`) name the
        // action even when the button text is rendered later by JS.
        var html = (document.documentElement.innerHTML || "").toLowerCase();
        var markupNeedles = productRuleArray("addToCartMarkupNeedles");
        for (var i = 0; i < markupNeedles.length; i++) {
            if (html.indexOf(markupNeedles[i]) >= 0) { return true; }
        }
        return false;
    }

    function hasRatingSignal() {
        if (document.querySelector('[itemprop="aggregateRating"], [itemprop="ratingValue"]')) { return true; }
        var html = (document.documentElement.innerHTML || "").toLowerCase();
        var needles = productRuleArray("ratingMarkupNeedles");
        for (var i = 0; i < needles.length; i++) {
            if (html.indexOf(needles[i]) >= 0) { return true; }
        }
        return false;
    }

    // Uses ProductPageRules.productPathPatterns: `_p0208315` (SAP Hybris),
    // `/dp/B09…` (Amazon), `/p/123` (Target/Best Buy), `/products/slug` (Shopify),
    // `/itm/123` (eBay).
    function urlLooksLikeProduct() {
        var path = location.pathname || "";
        var patterns = productRuleArray("productPathPatterns").map(function (pattern) {
            return new RegExp(pattern);
        });
        for (var i = 0; i < patterns.length; i++) {
            if (patterns[i].test(path)) { return true; }
        }
        return false;
    }

    // First non-empty <meta> content matching any of `names` (tried against both
    // `property` and `name` attributes).
    function metaContent(names) {
        for (var i = 0; i < names.length; i++) {
            var el = document.querySelector(
                'meta[property="' + names[i] + '"], meta[name="' + names[i] + '"]');
            var content = el && el.getAttribute("content");
            if (content && content.trim()) { return content.trim(); }
        }
        return "";
    }

    function injectLunaButton(target) {
        if (document.getElementById("queue-read-button")) { return; }
        // A <div role="button"> (not a <button>) so the host page's `button {…}`
        // CSS can't clamp its height and cut off the pill. Explicit resets +
        // inline-flex centering + a fully-rounded radius guarantee the pill shape.
        var btn = document.createElement("div");
        btn.id = "queue-read-button";
        btn.setAttribute("role", "button");
        btn.appendChild(document.createTextNode(target.label));
        applyStyle(btn, {
            position: "fixed", right: "16px",
            bottom: "calc(20px + env(safe-area-inset-bottom))",
            zIndex: "2147483647", background: QUEUE_INDIGO, color: "#ffffff",
            font: "600 16px/1 -apple-system, system-ui, sans-serif",
            boxSizing: "border-box", display: "inline-flex",
            alignItems: "center", justifyContent: "center", whiteSpace: "nowrap",
            border: "none", borderRadius: "999px", padding: "14px 22px",
            height: "auto", minHeight: "0", width: "auto", margin: "0",
            boxShadow: "0 6px 20px rgba(0,0,0,0.30)", cursor: "pointer",
            webkitTapHighlightColor: "transparent", touchAction: "manipulation",
            webkitAppearance: "none", appearance: "none"
        });
        btn.addEventListener("click", function () {
            btn.textContent = target.pressedLabel || "Opening Luna…";
            btn.style.opacity = "0.7";
            btn.style.pointerEvents = "none";
            var open = function () {
                window.location.href = target.url();
            };
            if (!target.captureContent) {
                open();
                return;
            }
            // Hand the app the already-unlocked page HTML so it renders that content
            // instead of re-fetching (which could re-lock outside Safari). Skip when
            // the page is too large for native messaging; the app then fetches the URL.
            var html = capturedHTML();
            if (html && html.length <= 1500000) {
                browser.runtime.sendMessage({ type: "saveContent", url: location.href, html: html })
                    .then(open).catch(open);
            } else {
                open();
            }
        });
        (document.body || document.documentElement).appendChild(btn);
    }

    // A pill deep-links ONLY into this extension's OWN containing app (which is
    // installed by definition): the native handler supplies the host's scheme
    // (`luna` / `lunareader` / `lunadownloader` / `lunapricetracker`) plus its
    // per-kind support flags. A page kind the host app doesn't handle shows no
    // pill at all — the central Luna app is the only host that shows all three.
    function ownSchemeTarget(context, sourceURL) {
        var scheme = context && context.scheme;
        if (!scheme) { return null; }
        return scheme + "://read?url=" + encodeURIComponent(sourceURL);
    }

    function readTarget(context) {
        if (!(context && context.supportsArticles)) { return null; }
        return {
            label: "📖  Read in Luna",
            captureContent: true,
            url: function () { return ownSchemeTarget(context, location.href); }
        };
    }

    function downloadTargetFor(context) {
        if (!(context && context.supportsMedia)) { return null; }
        return {
            label: "Download in Luna",
            captureContent: false,
            url: function () { return ownSchemeTarget(context, location.href); }
        };
    }

    // The "Track in Luna" button target for a recognized product page.
    function trackTargetFor(context) {
        if (!(context && context.supportsProducts)) { return null; }
        return {
            label: "Track in Luna",
            captureContent: false,
            url: function () { return ownSchemeTarget(context, location.href); }
        };
    }


    // The app's canonical platform table (PlatformRecognizer.rules, LunaURLClassification)
    // shared through the generated platform_hosts.generated.js (self.__LUNA_PLATFORM_HOSTS),
    // injected before this file by background.js -- guarded against drift by
    // PlatformHostsJSParityTests, same pattern as the news-hosts list below.
    function platformHosts(key) {
        var data = (typeof self !== "undefined") ? self.__LUNA_PLATFORM_HOSTS : undefined;
        return (data && data[key]) || [];
    }

    // Mirrors PlatformRecognizer for Downloader-relevant web platforms -- same host
    // lists (via platformHosts) AND the same path-shape requirements (a bare Bluesky
    // profile or Reddit subreddit/feed does NOT recognize; only a post does). These
    // pages are not article candidates, even when captions/comments push body text
    // over the reader threshold.
    function recognizedPlatformPage() {
        var host = (location.hostname || "").toLowerCase();
        var segments = location.pathname.split("/").filter(function (s) { return s.length > 0; });
        if (hostMatches(host, platformHosts("x"))) { return "x"; }
        if (hostMatches(host, platformHosts("bluesky")) && blueskyPostID(segments)) { return "bluesky"; }
        // Reddit classifies ONLY on an individual post permalink (comments / gallery
        // / redd.it short link / app-native share link), never on a subreddit or
        // home feed — mirrors PlatformRecognizer.reddit's `recognizes:` gate. Feed
        // suppression and the animated-media gate live in handleReddit.
        if (hostMatches(host, platformHosts("reddit")) && currentRedditIsPost()) { return "reddit"; }
        if (hostMatches(host, platformHosts("tiktok"))) { return "tiktok"; }
        if (hostMatches(host, platformHosts("instagram"))) { return "instagram"; }
        if (hostMatches(host, platformHosts("facebook"))) { return "facebook"; }
        if (hostMatches(host, platformHosts("youtube")) && currentYouTubeIsVideo(host, segments)) {
            return "youtube";
        }
        return null;
    }

    // Mirrors PlatformRecognizer.youtube: a concrete watch/short/embed/live video
    // or clip only, never the YouTube home page/channel/feed.
    function currentYouTubeIsVideo(host, segments) {
        function validID(value) {
            return typeof value === "string" && /^[A-Za-z0-9_-]{11}$/.test(value);
        }
        if (host === "youtu.be") { return validID(segments[0]); }
        if (segments[0] === "clip") { return !!nonEmptySegment(segments[1]); }
        try {
            if (validID(new URL(location.href).searchParams.get("v"))) { return true; }
        } catch (e) {}
        return ["shorts", "live", "embed", "v"].indexOf(segments[0]) >= 0
            && validID(segments[1]);
    }

    // The Bluesky post rkey from /profile/<author>/post/<rkey>, or null — mirrors
    // PlatformRecognizer's blueskyPostID structural check. Unlike a bare host match,
    // a bare profile (no /post/) does NOT recognize; only a post does.
    function blueskyPostID(segments) {
        var authorIndex = segments.indexOf("profile");
        if (authorIndex < 0 || segments.length <= authorIndex + 3 || segments[authorIndex + 2] !== "post") {
            return null;
        }
        return nonEmptySegment(segments[authorIndex + 3]);
    }

    // Visibility-only media gate for Downloader-platform pages. Saving/downloading a
    // URL still happens in the app when the user adds it manually; this only decides
    // whether Safari should proactively show the "Download in Luna" pill.
    function shouldShowDownloadPillForPlatform(platform) {
        if (platform === "reddit") { return redditPostHasMedia(); }
        return !looksLikeStaticImagePost();
    }

    function looksLikeStaticImagePost() {
        if (hasVideoOrAnimatedImageSignal()) { return false; }
        return hasStaticImagePostSignal();
    }

    function hasVideoOrAnimatedImageSignal() {
        if (document.querySelector(
            'meta[property="og:video"], meta[property="og:video:url"], '
            + 'meta[property="og:video:secure_url"], meta[name="twitter:player"]')) {
            return true;
        }
        var type = metaContent(["og:type", "twitter:card"]).toLowerCase();
        if (type.indexOf("video") >= 0 || type.indexOf("player") >= 0) { return true; }
        if (document.querySelector("video, source[type^='video/']")) { return true; }
        if (document.querySelector("img[src$='.gif'], img[src*='.gif?']")) {
            return true;
        }
        var urls = mediaURLCandidates();
        for (var i = 0; i < urls.length; i++) {
            if (urlLooksAnimatedOrVideo(urls[i])) { return true; }
        }
        return false;
    }

    function hasStaticImagePostSignal() {
        var type = metaContent(["og:type", "twitter:card"]).toLowerCase();
        var imageURL = metaContent(["og:image", "og:image:secure_url", "twitter:image", "twitter:image:src"]);
        if (!imageURL) { return false; }
        if (urlLooksAnimatedOrVideo(imageURL)) { return false; }
        if (type.indexOf("image") >= 0) { return true; }
        if (type === "summary_large_image" || type === "photo") { return true; }
        // Social post pages often omit a precise media type, but a primary preview
        // image with no video/player counterpart is the static-image shape we want
        // to suppress.
        return true;
    }

    function mediaURLCandidates() {
        var names = [
            "og:video", "og:video:url", "og:video:secure_url", "og:image",
            "og:image:secure_url", "twitter:image", "twitter:image:src"
        ];
        var urls = [];
        for (var i = 0; i < names.length; i++) {
            var els = document.querySelectorAll(
                'meta[property="' + names[i] + '"], meta[name="' + names[i] + '"]');
            for (var j = 0; j < els.length; j++) {
                var content = els[j].getAttribute("content");
                if (content && content.trim()) { urls.push(content.trim()); }
            }
        }
        return urls;
    }

    function urlLooksAnimatedOrVideo(raw) {
        if (!raw) { return false; }
        var url = raw.toLowerCase().split("#")[0].split("?")[0];
        return /\.(gif|gifv|webm|mp4|m4v|mov|m3u8)$/.test(url);
    }

    // MARK: - Reddit post-page + media gating
    //
    // Reddit's "Download in Luna" pill must appear ONLY on an individual post whose
    // primary content is animated image/video (never static image posts, the home
    // feed, a subreddit listing, a comment-history listing, or a text/link/poll
    // post). New Reddit is a client-side-navigating SPA, so we also watch for
    // soft-nav and re-evaluate.

    var redditNavWatcherStarted = false;
    var redditGeneration = 0;
    var redditRetryTimers = [];
    var lastRedditURL = "";

    function nonEmptySegment(s) { return (typeof s === "string" && s.length > 0) ? s : null; }

    // The base-36 post id when `segments` name a Reddit POST permalink, else null.
    // Structural matching (NOT indexOf("comments")): a subreddit literally named
    // "comments" (`/r/comments/top/`) is a feed, and `/user/<n>/comments/` with no
    // id is a comment-history listing — neither is a post.
    function redditPostID(segments) {
        if (!segments || segments.length === 0) { return null; }
        var first = segments[0];
        // /comments/<id>/…
        if (first === "comments") { return nonEmptySegment(segments[1]); }
        // /r/<sub>/comments/<id>/…  or  /user|u/<name>/comments/<id>/…
        if ((first === "r" || first === "user" || first === "u") && segments[2] === "comments") {
            return nonEmptySegment(segments[3]);
        }
        // /gallery/<id> (gallery permalinks).
        if (first === "gallery") { return nonEmptySegment(segments[1]); }
        return null;
    }

    // The opaque share token from Reddit's own app-native share link,
    // /r/<sub>/s/<token> — mirrors PlatformRecognizer.redditShareToken. Reddit only
    // resolves it via a live HTTP redirect, so it carries no decodable post id;
    // used only as a recognition gate (see currentRedditIsPost), never as an id.
    function redditShareToken(segments) {
        if (!segments || segments[0] !== "r" || segments.length <= 3
            || !segments[1] || segments[2] !== "s" || !segments[3]) {
            return null;
        }
        return segments[3];
    }

    // True when the CURRENT location is a recognized Reddit item — a post
    // permalink OR an app-native share link — mirroring PlatformRecognizer.reddit's
    // `recognizes` gate exactly. Id extraction (currentRedditPostID) stays
    // narrower: a share link recognizes but has no decodable id, same as Swift's
    // itemID staying nil for it.
    function currentRedditIsPost() {
        if (currentRedditPostID()) { return true; }
        var segments = location.pathname.split("/").filter(function (s) { return s.length > 0; });
        return redditShareToken(segments) !== null;
    }

    // A reddit / redd.it host (new reddit, old.reddit, or any redd.it subdomain,
    // e.g. i.redd.it) — mirrors PlatformRecognizer.reddit's suffix-matched host set.
    function isRedditHost() {
        var host = (location.hostname || "").toLowerCase();
        return hostMatches(host, platformHosts("reddit"));
    }

    // The reddit post id for the CURRENT location, or null on a feed/listing. The
    // exact "redd.it" host (not a subdomain like i.redd.it) is the short-link
    // redirector, whose one path segment IS the id — mirrors
    // PlatformRecognizer.redditPostID's identical exact-host special case.
    function currentRedditPostID() {
        var host = (location.hostname || "").toLowerCase();
        var segments = location.pathname.split("/").filter(function (s) { return s.length > 0; });
        if (host === "redd.it") { return nonEmptySegment(segments[0]); }
        return redditPostID(segments);
    }

    // True only when the current reddit POST page's primary content is animated
    // image/video. Cheap and null-safe. (Reddit's bot wall blocks
    // curl, so these mirror the documented server-rendered shapes rather than
    // freshly-scraped DOM):
    //   1. new reddit: `<shreddit-post post-type="…">` — the authoritative signal.
    //      qualify video/gif; disqualify image/gallery/text/self/link/poll/crosspost.
    //   2. `<meta property="og:video">` — video posts expose it.
    //   3. animated image/video URLs in primary meta/image/video attributes.
    //   4. old reddit: `#siteTable .thing.link` with a media `data-domain`
    //      (`v.redd.it`) or an animated/video URL; static `i.redd.it` images do not
    //      show the pill.
    function redditPostHasMedia() {
        var post = document.querySelector("shreddit-post");
        if (post) {
            var type = (post.getAttribute("post-type") || "").toLowerCase();
            if (["video", "gif", "gifv"].indexOf(type) >= 0) { return true; }
            if (["image", "gallery", "text", "self", "link", "poll", "crosspost", "prediction"].indexOf(type) >= 0) { return false; }
            // Unknown post-type: fall through to the other signals rather than guess.
        }

        if (hasVideoOrAnimatedImageSignal()) { return true; }

        var thing = document.querySelector("#siteTable .thing.link");
        if (thing) {
            var domain = (thing.getAttribute("data-domain") || "").toLowerCase();
            if (domain === "v.redd.it") { return true; }
            var dataURL = thing.getAttribute("data-url") || thing.getAttribute("data-permalink") || "";
            if (urlLooksAnimatedOrVideo(dataURL)) { return true; }
            var expando = thing.querySelector(".expando");
            if (expando && expando.querySelector("video, source[type^='video/'], img[src$='.gif'], img[src*='.gif?']")) { return true; }
        }

        return false;
    }

    // Whether a post container has hydrated enough to give a definitive media
    // verdict (new-reddit shreddit-post, or an old-reddit post row).
    function redditPostContainerPresent() {
        return !!(document.querySelector("shreddit-post")
            || document.querySelector("#siteTable .thing.link"));
    }

    // Entry point for ANY reddit host (post or feed). Starts the soft-nav watcher
    // once, then evaluates the current URL.
    function handleReddit(resp) {
        startRedditNavWatcher(resp);
        evaluateRedditPage(resp);
    }

    // (Re)evaluate the current reddit URL: drop any stale pill, cancel pending
    // retries (via the generation counter), and — on a post page — inject once the
    // media check is satisfied.
    function evaluateRedditPage(resp) {
        redditGeneration++;
        cancelRedditRetries();
        removeLunaButton();
        var target = downloadTargetFor(resp);
        if (!target) { return; }
        attemptRedditInjection(resp, target, 0);
    }

    // On a post page: inject when media is confirmed. If the post container hasn't
    // hydrated yet (new-reddit SPA), retry on a bounded schedule; a definitive
    // non-media verdict stops immediately (no pill).
    function attemptRedditInjection(resp, target, attempt) {
        var generation = redditGeneration;
        if (!currentRedditIsPost()) { return; }
        if (redditPostContainerPresent()) {
            if (redditPostHasMedia()) { injectLunaButton(target); }
            return;
        }
        // No container yet, but a gallery permalink is inherently media.
        if (redditPostHasMedia()) { injectLunaButton(target); return; }
        if (attempt >= 4) { return; }
        var timer = setTimeout(function () {
            if (generation !== redditGeneration) { return; }
            attemptRedditInjection(resp, target, attempt + 1);
        }, 1500);
        redditRetryTimers.push(timer);
    }

    // A ~1s poll (reddit hosts only) that re-evaluates when the SPA soft-navigates,
    // so feed→post gains the pill and post→feed loses it. Captures `resp` from the
    // initial message — no per-tick background round-trip.
    function startRedditNavWatcher(resp) {
        if (redditNavWatcherStarted) { return; }
        redditNavWatcherStarted = true;
        lastRedditURL = location.href;
        setInterval(function () {
            if (location.href === lastRedditURL) { return; }
            lastRedditURL = location.href;
            evaluateRedditPage(resp);
        }, 1000);
    }

    function cancelRedditRetries() {
        for (var i = 0; i < redditRetryTimers.length; i++) { clearTimeout(redditRetryTimers[i]); }
        redditRetryTimers = [];
    }

    function removeLunaButton() {
        var existing = document.getElementById("queue-read-button");
        if (existing && existing.parentNode) { existing.parentNode.removeChild(existing); }
    }

    function hostMatches(host, roots) {
        for (var i = 0; i < roots.length; i++) {
            if (host === roots[i] || host.slice(-("." + roots[i]).length) === "." + roots[i]) { return true; }
        }
        return false;
    }

    // The unlocked article HTML to hand the app, trimmed to fit native messaging's
    // size budget. A raw `documentElement.outerHTML` of a modern news page (WSJ) is
    // dominated by inline <script>/<style>/<svg> and easily exceeds the 1.5 MB cap —
    // which silently dropped the hand-off, so the app re-fetched the URL and re-locked.
    // Dropping those non-article nodes shrinks it by an order of magnitude while keeping
    // the rendered body AND the JSON-LD (`application/ld+json`) `articleBody` the app's
    // extractor falls back on. Falls back to the raw outerHTML if the clone fails.
    function capturedHTML() {
        try {
            var root = document.documentElement;
            if (!root) { return ""; }
            var clone = root.cloneNode(true);
            var drop = clone.querySelectorAll(
                'script:not([type="application/ld+json"]), style, noscript, svg, '
                + 'iframe, template, link, canvas');
            for (var i = 0; i < drop.length; i++) {
                var el = drop[i];
                if (el.parentNode) { el.parentNode.removeChild(el); }
            }
            return "<!doctype html>" + clone.outerHTML;
        } catch (e) {
            try { return document.documentElement ? document.documentElement.outerHTML : ""; }
            catch (e2) { return ""; }
        }
    }

    function applyStyle(el, style) {
        for (var key in style) {
            if (Object.prototype.hasOwnProperty.call(style, key)) {
                el.style[key] = style[key];
            }
        }
    }
})();
