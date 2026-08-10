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

    // ── Colour ──────────────────────────────────────────────────────────────────
    // Luna's per-app identity colours, hand-copied by VALUE from
    // `LunaSurfacePalette.baseColor(for:)` (LunaDesignSystem) because this target
    // links no package — the same tolerable hand-copy as the App-Group key
    // formats, and pinned to the Swift by `SafariSurfaceTintTests`.
    var SURFACE_TINTS = {
        luna: "#5856D6",
        reader: "#ADB5F6",
        downloader: "#CC7609",
        pricetracker: "#07FF9D"
    };
    // The central app's Luna indigo is also the fallback anywhere the native
    // handler didn't say which surface this is.
    var QUEUE_INDIGO = SURFACE_TINTS.luna;

    // **A pill is coloured by the KIND it saves, never by the app showing it.**
    // Those two rules agree everywhere it matters and only one of them is
    // expressible: a single-content app shows exactly one kind of pill, so the
    // Downloader's is always orange and the Price Tracker's always green — while
    // the central Luna app, the only host that shows all three, colours each pill
    // by the save it would make. App CHROME (the setup confirmation) is the other
    // way round: it belongs to the app, not to any page, and takes `surface`.
    var KIND_TINTS = {
        article: SURFACE_TINTS.reader,
        media: SURFACE_TINTS.downloader,
        product: SURFACE_TINTS.pricetracker
    };

    function surfaceTint(context) {
        var surface = context && context.surface;
        return (surface && SURFACE_TINTS[surface]) || QUEUE_INDIGO;
    }

    /// `#rrggbb` → [r, g, b]. Anything unparseable reads as the Luna indigo
    /// rather than as black, so a typo can never render an invisible pill.
    function tintChannels(hex) {
        var match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex || "");
        if (!match) { return [0x58, 0x56, 0xD6]; }
        return [parseInt(match[1], 16), parseInt(match[2], 16), parseInt(match[3], 16)];
    }

    /// WCAG relative luminance, which is what decides the text colour below.
    function tintLuminance(hex) {
        var channels = tintChannels(hex);
        var linear = channels.map(function (value) {
            var unit = value / 255;
            return unit <= 0.03928 ? unit / 12.92 : Math.pow((unit + 0.055) / 1.055, 2.4);
        });
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
    }

    // The identity colours span nearly the whole brightness range — the Price
    // Tracker's green is a near-neon and the Reader's periwinkle is pale, while
    // the Downloader's amber and the Luna indigo are deep — so a pill filled with
    // one of them cannot also have a fixed text colour. 0.19 is where white and
    // this near-black tie on contrast (1.05/(L+0.05) == (L+0.05)/0.0555), so
    // picking the winner keeps every pill legible without tempering the colour
    // the app is actually identified by.
    var TINT_INK = "#12121a";
    var TINT_CROSSOVER_LUMINANCE = 0.19;

    function tintForeground(hex) {
        return tintLuminance(hex) > TINT_CROSSOVER_LUMINANCE ? TINT_INK : "#ffffff";
    }

    function tintRGBA(hex, alpha) {
        return "rgba(" + tintChannels(hex).join(", ") + ", " + alpha + ")";
    }

    /// `hex` mixed `amount` of the way into `baseHex` — how the two INFORMATIONAL
    /// chips carry the app's colour. They report a price rather than offering an
    /// action, so they stay the dark chip they have always been and take the tint
    /// as a cast in it; filling them would make them read as a second button.
    function tintMixed(hex, baseHex, amount) {
        var tint = tintChannels(hex);
        var base = tintChannels(baseHex);
        // Back to `#rrggbb` rather than `rgb(…)`, so a mix stays a valid input to
        // every other helper here.
        return "#" + tint.map(function (value, index) {
            var mixed = Math.round(value * amount + base[index] * (1 - amount));
            return ("0" + Math.max(0, Math.min(255, mixed)).toString(16)).slice(-2);
        }).join("");
    }

    var CHIP_BASE = "#14141a";
    var CHIP_TINT_AMOUNT = 0.22;

    function chipBackground(hex) {
        return tintMixed(hex, CHIP_BASE, CHIP_TINT_AMOUNT);
    }

    /// The same tint, darkened only as far as it takes to be readable AS TEXT on
    /// white (4.5:1). A colour already dark enough is returned untouched, so the
    /// Luna indigo and the Downloader's amber are exactly themselves.
    function readableOnWhite(hex) {
        var candidate = hex;
        for (var step = 0; step < 12; step++) {
            if (1.05 / (tintLuminance(candidate) + 0.05) >= 4.5) { return candidate; }
            candidate = tintMixed(candidate, TINT_INK, 0.82);
        }
        return TINT_INK;
    }

    // For the WKWebView harnesses, which have no extension host.
    window.__lunaSurfaceTints = SURFACE_TINTS;
    window.__lunaKindTints = KIND_TINTS;
    window.__lunaTintForeground = tintForeground;

    // Generated from ProductPageRules.swift and injected immediately before this
    // script. No local fallback is intentional: a missing artifact must not silently
    // resurrect an independently-maintained Safari rule set.
    var PRODUCT_RULES = self.__LUNA_PRODUCT_RULES || {};

    // Every string this script renders, with its English default inline.
    // `browser.i18n.getMessage` returns "" for EVERY key unless the bundle keeps
    // `_locales/<locale>/messages.json` intact, and Xcode's synchronized-group
    // resource copy flattens that folder to the bundle root — which is what
    // turned the in-page pill into a bare padding-sized stub with no text. The
    // build phase (`scripts/update_safari_extension_branding.sh`) restores the
    // directory; these defaults make an empty lookup non-fatal regardless, and
    // are also what the standalone WKWebView test harnesses see (no `browser`).
    // Keep in sync with `_locales/en/messages.json` — SafariPillLabelTests.
    var MESSAGE_DEFAULTS = {
        unlockedWithLuna: "Unlocked with Luna",
        openingLuna: "Opening Luna…",
        readInLuna: "📖  Read in Luna",
        downloadInLuna: "Download in Luna",
        trackInLuna: "Track in Luna",
        findingVideo: "Finding video…",
        videoUnplayable: "This one can't play here",
        closeVideo: "Close",
        setupCompleteTitle: "Nice!\nYou're all set up",
        // `{app}`, NOT `$APP$`: `$NAME$` is WebExtension i18n PLACEHOLDER syntax, and
        // WebKit resolves it by asking the message entry's `placeholders` dictionary
        // for that name. An entry that declares none hands the lookup a null object
        // and `WebExtensionLocalization::localizedStringForKey` SEGFAULTS THE WHOLE
        // WEB CONTENT PROCESS — which Safari shows as "A problem repeatedly occurred"
        // on every site, because the crash lands before the one-shot flag below is
        // recorded. Substitution is ours to do (see `presentSetupCelebration`), so
        // the catalog must never carry a `$…$` token. Guarded by SafariPillLabelTests.
        returnToApp: "Return to {app}",
        // `{price}`/`{date}`, substituted the same way as `{app}` above --
        // never `$`-style syntax (see the note on `returnToApp`).
        wasPriceOnDate: "Was {price} on {date}",
        findingSellers: "Finding other sellers…",
        // `{price}`/`{seller}` -- same rule again, never `$`-style syntax.
        priceAtSeller: "{price} at {seller}"
    };

    function localizedMessage(key) {
        var localized = "";
        if (typeof browser !== "undefined" && browser.i18n) {
            localized = browser.i18n.getMessage(key) || "";
        }
        return localized || MESSAGE_DEFAULTS[key] || "";
    }
    window.__lunaLocalizedMessage = localizedMessage;
    window.__lunaMessageDefaults = MESSAGE_DEFAULTS;

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
            // The one-shot "you're all set up" confirmation takes the whole page,
            // and is deliberately independent of pill eligibility: the app sends
            // the user to an ordinary web page to prove the extension runs, and
            // that page is frequently one this app would never offer a pill on
            // (Wikipedia in Downloader) — while `mode: "never"` silences pills,
            // not the proof that setup worked. Pills resume when it dismisses.
            if (resp && resp.celebrateSetup) {
                presentSetupCelebration(resp, function () { offerLunaButton(resp); });
                return;
            }
            offerLunaButton(resp);
        }).catch(function () {});

        // Reveal the article body in Safari (the Referer rewrite that unlocks the
        // server response is applied declaratively by the background ruleset; this
        // strips the leftover overlay/clamp so the reader — and the user, right
        // here in Safari — sees the full article). The native handler answers
        // `enabled` only for article-handling hosts (Reader and the central Luna
        // app) — unlocking is article handling, so the Downloader and Price
        // Tracker extensions never reveal.
        browser.runtime.sendMessage({ type: "bypassEnabled" }).then(function (resp) {
            if (!resp || !resp.enabled) { return; }
            // A publisher that answers a premium article with a server-side redirect to
            // its own subscribe page leaves NOTHING on the page to reveal — the article
            // isn't in this document. Go back to the article the interstitial names
            // (once) instead; when that fires we're navigating away, so skip the
            // cleanup for this document.
            if (escapeSubscribeInterstitial()) { return; }
            revealArticle();
        }).catch(function () {});
    }

    /// Decides which pill (if any) this page earns, from the native context.
    function offerLunaButton(resp) {
        var mode = (resp && resp.mode) || "all";
        if (mode === "never") { return; }
        var platform = recognizedPlatformPage();
        // Reddit is media-gated and SPA-aware; its own handler owns injection,
        // the retry-on-hydration schedule, and the soft-nav watcher.
        if (platform === "reddit") { handleReddit(resp); return; }
        if (platform) {
            if (!shouldShowDownloadPillForPlatform(platform)) { return; }
            // The in-page player opens by ITSELF on a page whose subject is a
            // video. The pill is then the way back to it after a dismissal —
            // and on a page that never earns one, it still carries the hand-off
            // navigation into the app that it always did.
            var downloadTarget = videoOverlayTargetFor(resp);
            if (!downloadTarget) { return; }
            injectLunaButton(downloadTarget);
            // A target with nothing to present is the player turned OFF in
            // Settings: the pill is then exactly what it was before the player
            // existed, and nothing opens over the page uninvited.
            if (typeof downloadTarget.present === "function") {
                autoPresentVideoOverlay(platform, downloadTarget, 0);
            }
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
            handleProductPage(resp);
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
    }

    // The whole pill decision, for a test that wants the REAL route to the pill
    // (which target a page earns, and what happens once it lands) rather than a
    // hand-built target handed straight to an injector.
    window.__lunaOfferLunaButton = offerLunaButton;

    // One-shot re-check of just the article branch (mirrors the tail of
    // `offerLunaButton` above) for the 2500ms SPA retry.
    function tryInjectArticleButton(mode, resp) {
        if (!isArticlePage()) { return; }
        if (mode === "onlyLocked" && !pageIsLocked()) { return; }
        var target = readTarget(resp);
        if (target) { injectLunaButton(target); }
    }

    // ── Publisher subscribe interstitials ────────────────────────────────────────
    // Some publishers don't overlay a wall on the article; they REDIRECT the request
    // to their own subscribe page (News Corp Australia:
    // `…/subscribe/news/1/?dest=<article>&memtype=anonymous&mode=premium`). Safari's
    // address bar then shows the interstitial, and there is no article in the DOM to
    // unlock — the cleanup below has nothing to work with. So leave: navigate back to
    // the page the interstitial itself names, asking for its AMP rendering, which on
    // those sites is served un-metered (the app's `.ampQuery` bypass does the same
    // thing over URLSession — `AMPQueryBypass`).
    //
    // Deliberately narrow, because this MOVES the user:
    //   • only on a known news/article host (the shared `__LUNA_NEWS_HOSTS` list),
    //   • only on a SUBSCRIBE-family path — never a sign-in / register / checkout
    //     page, where hopping to `?next=…` would abandon something the user started,
    //   • only to an absolute http(s) target on the SAME site that isn't itself an
    //     interstitial (so a hostile `?dest=` can't make this an open redirect), and
    //   • once per target per tab, so a site that redirects straight back can't loop.

    // Mirrors the subscribe half of NewsAggregatorUnwrapper.interstitialPathSegments.
    var SUBSCRIBE_PATH_SEGMENTS = ["subscribe", "subscribes", "subscription",
        "subscriptions", "paywall", "check_cookie.html"];
    // Mirrors NewsAggregatorUnwrapper.interstitialPathSegments in full — used to
    // reject a target that is itself an interstitial.
    var INTERSTITIAL_PATH_SEGMENTS = SUBSCRIBE_PATH_SEGMENTS.concat(
        ["signin", "sign-in", "login", "log-in", "register", "checkout"]);
    // Mirrors NewsAggregatorUnwrapper.interstitialTargetParams.
    var INTERSTITIAL_TARGET_PARAMS = ["dest", "destination", "returnurl", "return_url",
        "return", "redirect", "redirecturl", "redirect_uri", "url", "next", "targeturl"];

    function pathHasSegment(pathname, segments) {
        return pathname.split("/").some(function (segment) {
            return segments.indexOf(segment.toLowerCase()) >= 0;
        });
    }

    function sameSite(a, b) {
        var x = a.replace(/^www\./, ""), y = b.replace(/^www\./, "");
        return x === y || x.endsWith("." + y) || y.endsWith("." + x);
    }

    /// The article a subscribe interstitial is holding, as an absolute URL string, or
    /// null when this page isn't one (the overwhelmingly common case). Test hook:
    /// `window.__lunaSubscribeInterstitialTarget`.
    function subscribeInterstitialTarget() {
        if (!isKnownArticleHost()) { return null; }
        if (!pathHasSegment(location.pathname, SUBSCRIBE_PATH_SEGMENTS)) { return null; }
        var candidates = [];
        try {
            var params = new URL(location.href).searchParams;
            INTERSTITIAL_TARGET_PARAMS.forEach(function (name) {
                var value = params.get(name);
                if (value) { candidates.push(value); }
            });
        } catch (e) {}
        // The same publishers also name the held article in `og:url` (with
        // `og:type=article`), which is what the browser-tier cleanup script reads.
        var ogType = document.querySelector('meta[property="og:type"][content]');
        var ogURL = document.querySelector('meta[property="og:url"][content]');
        if (ogURL && ogType && (ogType.getAttribute("content") || "").toLowerCase() === "article") {
            candidates.push(ogURL.getAttribute("content"));
        }
        for (var i = 0; i < candidates.length; i++) {
            var target;
            try { target = new URL(decodeURIComponent(candidates[i]), location.href); } catch (e) { continue; }
            if (target.protocol !== "https:" && target.protocol !== "http:") { continue; }
            if (!sameSite(target.hostname.toLowerCase(), location.hostname.toLowerCase())) { continue; }
            if (pathHasSegment(target.pathname, INTERSTITIAL_PATH_SEGMENTS)) { continue; }
            if (target.pathname === location.pathname) { continue; }
            return target.href;
        }
        return null;
    }

    /// Same transform as Swift's `AMPQueryBypass.ampQueryURL` — a bare `amp` flag
    /// appended, existing query preserved. A site that doesn't route AMP by query
    /// simply ignores it and serves the article.
    function withAMPFlag(urlString) {
        try {
            var url = new URL(urlString);
            if (url.searchParams.has("amp") || url.pathname.toLowerCase().endsWith("/amp")) {
                return url.href;
            }
            url.search = url.search ? url.search + "&amp" : "?amp";
            url.hash = "";
            return url.href;
        } catch (e) { return urlString; }
    }

    /// Leaves a subscribe interstitial for the article it holds. Returns true when a
    /// navigation was started (the caller then does nothing else with this document).
    function escapeSubscribeInterstitial() {
        var target = subscribeInterstitialTarget();
        if (!target) { return false; }
        var destination = withAMPFlag(target);
        // One attempt per destination per tab: if the site bounces us straight back to
        // the interstitial, we stop rather than ping-pong.
        var key = "__lunaInterstitialHop:" + destination;
        try {
            if (sessionStorage.getItem(key)) { return false; }
            sessionStorage.setItem(key, "1");
        } catch (e) {}
        // `replace`, not `assign`: the interstitial doesn't belong in history, and Back
        // must return to wherever the user actually came from.
        location.replace(destination);
        return true;
    }

    window.__lunaSubscribeInterstitialTarget = subscribeInterstitialTarget;
    window.__lunaWithAMPFlag = withAMPFlag;

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
                        // holding real prose, and only remove a content-less overlay.
                        if (articleChars(el) > 400) { reveal(el); } else { el.remove(); }
                        announceUnlock();
                    });
                });
                // AMP subscriber gating (`amp-subscriptions`): the document ships BOTH
                // the story and the pitch, and the AMP runtime picks between them after
                // load — `[subscriptions-section="content"]` is the article, anything
                // else (`content-not-granted`, its preview) is the gate. Dropping the
                // gate and the attribute that hides the content reveals the body the
                // page already contains. Mirrors Swift's `AMPQueryBypass
                // .extractableHTML` (the silent tier) and upstream's
                // `amp_unhide_subscr_section`.
                document.querySelectorAll("[subscriptions-section]").forEach(function (el) {
                    var role = (el.getAttribute("subscriptions-section") || "").toLowerCase();
                    if (role === "content") {
                        el.removeAttribute("subscriptions-section");
                        el.style.removeProperty("display");
                    } else {
                        el.remove();
                        announceUnlock();
                    }
                });
                document.querySelectorAll("[amp-access-hide]").forEach(function (el) {
                    el.removeAttribute("amp-access-hide");
                    announceUnlock();
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
                // Un-clamp the genuine "faded teaser" a metered wall applies to its
                // content container: a HEIGHT limit COMBINED WITH a visual fade
                // (mask-image / linear-gradient / blur). Requiring BOTH is deliberate —
                // a bare `overflow:hidden` or a bare `max-height` is ubiquitous layout
                // styling, and force-revealing those (especially the repeated pass below,
                // on a complex SPA) rewrites the site's own layout/scroll containers and
                // can collapse the page to blank. Only the clamp/fade properties are
                // cleared — never height/display/visibility/opacity — so revealing the
                // hidden body can't disturb the layout engine. Prose-guarded (>= 2 real
                // paragraphs); does NOT announce an unlock (a benign clamp isn't a wall).
                document.querySelectorAll("[style]").forEach(function (el) {
                    var s = (el.getAttribute("style") || "").toLowerCase();
                    var heightClamped = /max-height\s*:/.test(s);
                    var faded = s.indexOf("mask-image") >= 0 || s.indexOf("-webkit-mask") >= 0
                        || s.indexOf("linear-gradient") >= 0 || /filter\s*:\s*blur/.test(s);
                    if (heightClamped && faded && articleChars(el) > 400) {
                        el.style.maxHeight = "none";
                        el.style.webkitMaskImage = "none"; el.style.maskImage = "none";
                        el.style.filter = "none"; el.style.webkitFilter = "none";
                        if (/overflow\s*:\s*hidden/.test(s)) { el.style.overflow = "visible"; }
                    }
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
        toast.appendChild(document.createTextNode(
            localizedMessage("unlockedWithLuna")));
        applyStyle(toast, {
            position: "fixed", left: "50%",
            // The button pill is ~48px tall at bottom 20px; 84px clears it plus a gap.
            bottom: "calc(84px + env(safe-area-inset-bottom))",
            transform: "translateX(-50%)",
            // Unlocking IS article handling (only article-capable hosts reveal at
            // all), so the toast carries the article tint the pill below it does.
            zIndex: "2147483647", background: KIND_TINTS.article,
            color: tintForeground(KIND_TINTS.article),
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
        if (hasStructuralListingShape()) { return false; }
        if (isDocPathURL()) { return false; }
        // A page whose content IS a sign-in form isn't an article — but a document-wide
        // `input[type=password]` is not that test. Publishers ship an inline sign-in
        // form in the site header (theparisreview.org carries two, one per breakpoint)
        // and a metered page routinely puts one under the teaser, so this rejected real
        // articles on sight: together with the structural shapes above it was the
        // second reason a Paris Review interview never got the pill, and removing the
        // two fields from that DOM flips this function to true on its own. A page that
        // declares itself an article is therefore exempt here too; a genuine login or
        // subscribe page declares no article and still fails.
        if (!pageDeclaresArticle() && document.querySelector('input[type="password"]')) {
            return false;
        }

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
    // Safari side must not be strictly weaker: POSITIVE article metadata
    // (og:type=article, or an Article/NewsArticle/BlogPosting JSON-LD node) decides
    // "article" there, and only a page carrying NO article declaration at all falls
    // back to the full index veto — so a publisher homepage on the same host still
    // gets no pill.
    //
    // Unknown hosts: an index vetoes, then the prose scorer decides. The veto's
    // STRUCTURAL half no longer applies to a page that declares itself an article
    // (see `looksLikeNonArticleIndex`) — that was what silenced the pill on
    // theparisreview.org — but the scorer still has to find real prose, so a thin
    // metered teaser on an unknown host stays pill-less. On save the app
    // re-classifies properly via LunaIngest either way.
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

    // The two purely STRUCTURAL listing shapes: a cluster of sibling `<article>`
    // elements, and a page that is mostly links. Neither says anything about a page's
    // kind on its own, because both are routine on real articles — a "read next" rail
    // of related-story `<article>` cards (Business Insider ships six; a Paris Review
    // interview ships thirteen "more from this issue" cards), and the link density a
    // metered body leaves behind once the prose is cut. So a page that DECLARES itself
    // an article is exempt, on every host: a rail of cards is not a property of the
    // HOST, and while the known-news list had an exemption, a declared article
    // anywhere off that list was rejected by markup that carried no such meaning.
    //
    // Shared by the index veto and the prose scorer, which each carried their OWN copy
    // of these two lines — the scorer's copy is why theparisreview.org stayed
    // pill-less even after the veto learned to stand down, and why they must not drift
    // apart again.
    function hasStructuralListingShape() {
        var body = document.body;
        if (!body) { return false; }
        if (pageDeclaresArticle()) { return false; }
        if (document.querySelectorAll("article").length >= 4) { return true; }
        return wholePageLinkDensity(body) > 0.5;
    }

    // An index is not something Luna can read as one article, even when its publisher
    // is in the known-news host list. These are intentionally structural signals rather
    // than site names:
    //   * repeated <article>s or a link-dense page are universal listing shapes;
    //   * a page declaring itself as a landing / collection / search / site page AND
    //     exposing a cluster of headline-sized links is a publisher front/section page.
    // Requiring both metadata and the visible link cluster for the latter avoids
    // rejecting a genuine article merely because it also declares generic WebPage data.
    // A page's own LISTING declaration vetoes even when it also claims to be an
    // article, so a front page can't slip through on that claim alone.
    function looksLikeNonArticleIndex() {
        if (!document.body) { return false; }
        if (hasStructuralListingShape()) { return true; }
        return declaresListingPage() && headlineLinkCount() >= 5;
    }
    // Exposed for the bare-WKWebView harness, and specifically so
    // `SafariIndexVetoParityTests` can hold this against its Swift twin,
    // `ListingPage.isNonContentPage` (LunaHTMLClassification). The app used to have
    // no index veto at all, which is how pages that never earn a pill here still
    // reached the recents tray and the archive reader.
    window.__lunaLooksLikeNonArticleIndex = looksLikeNonArticleIndex;

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

    // ── Passive product snapshots + the "Was $X" history pill ──────────────────
    // Extraction is independent of the pill-suggestion mode: a snapshot is
    // local, non-refreshing product data, never a save. Structured price data
    // ONLY -- no heuristic/rendered-DOM tier, mirroring "the price is
    // mandatory" (a ProductInfo never exists without one).

    var TRACKING_QUERY_PARAM_NAMES = ["srsltid", "gclid", "ref"];
    var TRACKING_QUERY_PARAM_PREFIXES = ["utm_"];

    function stripTrackingParams(url) {
        try {
            var parsed = new URL(url);
            var host = parsed.hostname.toLowerCase();
            var toDelete = [];
            parsed.searchParams.forEach(function (_value, key) {
                var lower = key.toLowerCase();
                if (TRACKING_QUERY_PARAM_NAMES.indexOf(lower) >= 0) { toDelete.push(key); return; }
                for (var i = 0; i < TRACKING_QUERY_PARAM_PREFIXES.length; i++) {
                    if (lower.indexOf(TRACKING_QUERY_PARAM_PREFIXES[i]) === 0) { toDelete.push(key); return; }
                }
                if (lower === "tag" && host.indexOf("amazon.") >= 0) { toDelete.push(key); }
            });
            for (var j = 0; j < toDelete.length; j++) { parsed.searchParams.delete(toDelete[j]); }
            return parsed.toString();
        } catch (e) { return url; }
    }

    function canonicalProductURL() {
        var link = document.querySelector('link[rel="canonical"]');
        var href = link && link.getAttribute("href");
        if (href) {
            try {
                var resolved = new URL(href, location.href);
                if (resolved.hostname === location.hostname) { return stripTrackingParams(resolved.href); }
            } catch (e) {}
        }
        return stripTrackingParams(location.href);
    }

    function stringOrNumberField(obj, key) {
        var value = obj && obj[key];
        if (typeof value === "string" && value.trim()) { return value.trim(); }
        if (typeof value === "number" && isFinite(value)) { return String(value); }
        return null;
    }

    // Same walk as findProductNodeWithPrice, but returns the NODE (so its
    // brand/identifiers/name can be read) instead of a boolean.
    function findProductNode(node) {
        if (!node || typeof node !== "object") { return null; }
        if (Array.isArray(node)) {
            for (var i = 0; i < node.length; i++) {
                var found = findProductNode(node[i]);
                if (found) { return found; }
            }
            return null;
        }
        if (typeContainsProduct(node["@type"]) && offerPrice(node) !== null) { return node; }
        for (var key in node) {
            if (Object.prototype.hasOwnProperty.call(node, key)) {
                var nested = findProductNode(node[key]);
                if (nested) { return nested; }
            }
        }
        return null;
    }

    function jsonLDProductNode() {
        var scripts = document.querySelectorAll('script[type="application/ld+json"]');
        for (var i = 0; i < scripts.length; i++) {
            var parsed;
            try { parsed = JSON.parse(scripts[i].textContent || ""); } catch (e) { continue; }
            var found = findProductNode(parsed);
            if (found) { return found; }
        }
        return null;
    }

    // The offer's currency -- mirrors offerPrice's candidate walk.
    function offerCurrency(node) {
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
            var currency = offer.priceCurrency;
            if (!currency && offer.priceSpecification && typeof offer.priceSpecification === "object") {
                currency = offer.priceSpecification.priceCurrency;
            }
            if (typeof currency === "string" && currency.trim()) { return currency.trim(); }
        }
        return null;
    }

    function jsonLDIdentifiers(node) {
        var offers = node.offers;
        var offerNode = null;
        if (offers && typeof offers === "object" && !Array.isArray(offers)) {
            offerNode = offers;
        } else if (Array.isArray(offers) && offers.length > 0 && typeof offers[0] === "object") {
            offerNode = offers[0];
        }
        var gtinKeys = ["gtin13", "gtin12", "gtin14", "gtin8", "gtin", "isbn"];
        var gtin = null;
        for (var i = 0; i < gtinKeys.length; i++) {
            gtin = stringOrNumberField(node, gtinKeys[i])
                || (offerNode && stringOrNumberField(offerNode, gtinKeys[i]));
            if (gtin) { break; }
        }
        var mpn = stringOrNumberField(node, "mpn") || (offerNode && stringOrNumberField(offerNode, "mpn"));
        var sku = stringOrNumberField(node, "sku") || (offerNode && stringOrNumberField(offerNode, "sku"));
        var productID = stringOrNumberField(node, "productID")
            || (offerNode && stringOrNumberField(offerNode, "productID"));
        var brand = null;
        if (node.brand) {
            brand = (typeof node.brand === "string") ? node.brand : (node.brand.name || null);
        }
        return { gtin: gtin, mpn: mpn, sku: sku, productID: productID, brand: brand };
    }

    // Meta/microdata price + currency -- same tier as looksLikeProductPage's
    // own checks, but keeps the actual value rather than a yes/no.
    function metaPriceAndCurrency() {
        var amountRaw = metaContent(productRuleArray("productPriceMetaNames"));
        if (parsePriceNumber(amountRaw) === null) { return null; }
        var currency = metaContent(["product:price:currency", "og:price:currency", "product:currency"]);
        return { amount: amountRaw, currency: currency || null };
    }

    function microdataPriceAndCurrency() {
        var el = document.querySelector('[itemprop="price"]');
        if (!el) { return null; }
        var raw = el.getAttribute("content") || el.textContent || "";
        if (parsePriceNumber(raw) === null) { return null; }
        var currencyEl = document.querySelector('[itemprop="priceCurrency"]');
        var currency = currencyEl && (currencyEl.getAttribute("content") || currencyEl.textContent || "");
        return { amount: raw, currency: (currency || "").trim() || null };
    }

    function microdataIdentifiers() {
        var props = ["gtin13", "gtin12", "gtin14", "gtin8", "gtin", "sku", "mpn", "productID"];
        var result = {};
        for (var i = 0; i < props.length; i++) {
            var el = document.querySelector('[itemprop="' + props[i] + '"]');
            var value = el && (el.getAttribute("content") || el.textContent || "").trim();
            if (value) {
                var key = (props[i].indexOf("gtin") === 0 || props[i] === "isbn") ? "gtin" : props[i];
                if (!result[key]) { result[key] = value; }
            }
        }
        var brandEl = document.querySelector('[itemprop="brand"]');
        var brand = brandEl && (brandEl.getAttribute("content") || brandEl.textContent || "").trim();
        if (brand) { result.brand = brand; }
        return result;
    }

    // Amazon ASIN / eBay item / Walmart / Target retailer item ids, read
    // straight out of the URL path.
    function retailerItemIDFromURL() {
        var path = location.pathname || "";
        var match;
        if ((match = path.match(/\/(?:dp|gp\/product)\/([A-Z0-9]{6,})/i))) { return match[1]; }
        if ((match = path.match(/\/itm\/(\d{4,})/))) { return match[1]; }
        if ((match = path.match(/\/ip\/[^/]*\/(\d{4,})/))) { return match[1]; }
        if ((match = path.match(/-\/A-(\d+)/))) { return match[1]; }
        return null;
    }

    function productSnapshotName() {
        var node = jsonLDProductNode();
        if (node && typeof node.name === "string" && node.name.trim()) { return node.name.trim(); }
        var microdataEl = document.querySelector('[itemprop="name"]');
        var microdataName = microdataEl
            && (microdataEl.getAttribute("content") || microdataEl.textContent || "").trim();
        if (microdataName) { return microdataName; }
        var og = metaContent(["og:title"]);
        if (og) { return og; }
        return (document.title || "").trim();
    }

    // The passive product snapshot this page offers, or null with no
    // STRUCTURED price (no heuristic/rendered-DOM tier).
    function extractProductSnapshot() {
        var name = productSnapshotName();
        if (!name) { return null; }

        var node = jsonLDProductNode();
        var amount = null, currency = null, identifiers = {};
        if (node) {
            var offerAmount = offerPrice(node);
            if (offerAmount === null) { return null; }
            amount = String(offerAmount);
            currency = offerCurrency(node);
            identifiers = jsonLDIdentifiers(node);
        } else {
            var found = metaPriceAndCurrency() || microdataPriceAndCurrency();
            if (!found) { return null; }
            amount = found.amount;
            currency = found.currency;
            identifiers = microdataIdentifiers();
        }
        if (!currency) { return null; }

        var retailerItemID = metaContent(["product:retailer_item_id"]) || retailerItemIDFromURL();
        return {
            name: name,
            price: amount,
            currency: currency,
            url: canonicalProductURL(),
            gtin: identifiers.gtin || null,
            mpn: identifiers.mpn || null,
            sku: identifiers.sku || null,
            productID: identifiers.productID || null,
            retailerItemID: retailerItemID || null,
            brand: identifiers.brand || metaContent(["product:brand", "og:brand"]) || null
        };
    }

    // For the WKWebView harness -- see ProductSnapshotJSFixtureParityTests.
    window.__lunaExtractProductSnapshot = extractProductSnapshot;

    // The price EXACTLY as the native side reported it, in its own currency --
    // never a hardcoded symbol. `Intl` throws on an unrecognised currency code,
    // and formats NaN as "$NaN", so both fall back to the plain pair.
    function formatHistoryPrice(amount, currency) {
        var value = parseFloat(amount);
        if (!isFinite(value)) { return amount + " " + currency; }
        try {
            return new Intl.NumberFormat(undefined, { style: "currency", currency: currency })
                .format(value);
        } catch (e) { return amount + " " + currency; }
    }

    function formatHistoryDate(day) {
        try {
            var parts = (day || "").split("-").map(function (p) { return parseInt(p, 10); });
            var date = new Date(Date.UTC(parts[0], parts[1] - 1, parts[2]));
            return date.toLocaleDateString(undefined, { day: "numeric", month: "numeric", year: "2-digit" });
        } catch (e) { return day || ""; }
    }

    // The history pill is informational only -- pointer-events:none, so it
    // never swallows a tap the underlying page would otherwise get.
    function injectHistoryPill(historyResp, stacked) {
        if (document.getElementById("queue-history-pill")) { return; }
        var label = localizedMessage("wasPriceOnDate")
            .replace("{price}", formatHistoryPrice(historyResp.amount, historyResp.currency))
            .replace("{date}", formatHistoryDate(historyResp.day));
        var pill = document.createElement("div");
        pill.id = "queue-history-pill";
        pill.appendChild(document.createTextNode(label));
        applyStyle(pill, {
            position: "fixed", right: "16px",
            bottom: stacked
                ? "calc(70px + env(safe-area-inset-bottom))"
                : "calc(20px + env(safe-area-inset-bottom))",
            zIndex: "2147483647", background: chipBackground(KIND_TINTS.product),
            color: "#ffffff",
            font: "500 13px/1 -apple-system, system-ui, sans-serif",
            boxSizing: "border-box", display: "inline-flex",
            alignItems: "center", justifyContent: "center", whiteSpace: "nowrap",
            border: "none", borderRadius: "999px", padding: "8px 14px",
            margin: "0", boxShadow: "0 4px 14px rgba(0,0,0,0.25)",
            pointerEvents: "none"
        });
        (document.body || document.documentElement).appendChild(pill);
    }

    // Renders whatever the productSnapshot round trip earned: the history
    // pill (stacked above Track when both show; alone when the page is
    // already tracked) and/or the Track pill (skipped once tracked).
    function renderProductPills(context, historyResp) {
        var hasHistory = !!(historyResp && historyResp.hasHistory);
        var isTracked = !!(historyResp && historyResp.isTracked);
        if (hasHistory) { injectHistoryPill(historyResp, !isTracked); }
        if (!isTracked) {
            var trackTarget = trackTargetFor(context);
            if (trackTarget) { injectLunaButton(trackTarget); }
        }
    }

    // For the WKWebView harness -- drives the render decision directly from a
    // stubbed `productSnapshot` reply, the same shape background.js hands
    // back from the native round trip. See ProductHistoryPillRenderTests.
    window.__lunaRenderProductPills = renderProductPills;

    // ── The alternative-seller pill ─────────────────────────────────────────────
    // "Is this cheaper somewhere else, right now?" -- answered natively by
    // ComparableSellerFinder (stored prices first, then a constrained live
    // fan-out). It occupies the SAME slot the history pill would, because both
    // say something about this product's price and only one of them can be the
    // more useful thing to say: a better price available NOW beats a lower one
    // from the past. So the lookup runs first and the history pill is rendered
    // only if the lookup comes back empty -- which is also the whole of the
    // fallback contract (`renderProductPills`, untouched).
    var SELLER_PILL_ID = "queue-seller-pill";
    // Longer than the finder's own 18s budget, so a native side that answers
    // late still wins over this backstop and only a DEAD one trips it.
    var COMPARABLE_TIMEOUT = 25000;
    // One-shot: a page gets ONE lookup. Set before any DOM work, for the same
    // reason the setup celebration's flag is (see presentSetupCelebration).
    var sellerLookupStarted = false;

    // The native round trip, behind a swappable reference -- the WKWebView test
    // harness has no extension host at all (`browser` is undefined).
    var comparableSellersRequest = function (snapshot) {
        if (typeof browser === "undefined") { return Promise.resolve({ found: false }); }
        return browser.runtime.sendMessage({ type: "comparableSellers", snapshot: snapshot });
    };
    window.__lunaSetComparableSellersRequest = function (fn) { comparableSellersRequest = fn; };

    // Resolves to the reply, or to "nothing found" if the native side never
    // answers: a promise that never settles would leave the spinner pill up
    // forever and the history pill permanently suppressed behind it.
    function requestComparableSellers(snapshot) {
        return new Promise(function (resolve) {
            var settled = false;
            var finish = function (result) {
                if (settled) { return; }
                settled = true;
                resolve(result && result.found && result.url ? result : null);
            };
            setTimeout(function () { finish(null); }, COMPARABLE_TIMEOUT);
            try {
                comparableSellersRequest(snapshot).then(finish, function () { finish(null); });
            } catch (e) {
                finish(null);
            }
        });
    }

    function sellerPillStyle(stacked, tappable) {
        return {
            position: "fixed", right: "16px",
            bottom: stacked
                ? "calc(70px + env(safe-area-inset-bottom))"
                : "calc(20px + env(safe-area-inset-bottom))",
            zIndex: "2147483647", background: chipBackground(KIND_TINTS.product),
            color: "#ffffff",
            font: "500 13px/1 -apple-system, system-ui, sans-serif",
            boxSizing: "border-box", display: "inline-flex",
            alignItems: "center", justifyContent: "center", whiteSpace: "nowrap",
            border: "none", borderRadius: "999px", padding: "8px 14px",
            margin: "0", boxShadow: "0 4px 14px rgba(0,0,0,0.25)",
            pointerEvents: tappable ? "auto" : "none",
            cursor: tappable ? "pointer" : "default",
            webkitTapHighlightColor: "transparent", touchAction: "manipulation"
        };
    }

    // The waiting state: the same pill shape as the answer will be, with a
    // pulsing dot, so the answer replaces it in place rather than making the
    // page's bottom-right corner jump.
    function injectSellerSpinnerPill(stacked) {
        if (document.getElementById(SELLER_PILL_ID)) { return; }
        var pill = document.createElement("div");
        pill.id = SELLER_PILL_ID;
        pill.setAttribute("data-luna-state", "loading");

        var dot = document.createElement("span");
        applyStyle(dot, {
            display: "inline-block", width: "6px", height: "6px", borderRadius: "999px",
            background: "#ffffff", marginRight: "8px", opacity: "0.6"
        });
        // Web Animations rather than a @keyframes stylesheet: no style element
        // to inject into someone else's page, and a browser without it simply
        // shows a static dot.
        if (typeof dot.animate === "function") {
            dot.animate(
                [{ opacity: 0.3 }, { opacity: 1 }, { opacity: 0.3 }],
                { duration: 1200, iterations: Infinity });
        }
        pill.appendChild(dot);
        pill.appendChild(document.createTextNode(localizedMessage("findingSellers")));
        applyStyle(pill, sellerPillStyle(stacked, false));
        (document.body || document.documentElement).appendChild(pill);
    }

    // The answer: tappable, and it navigates to the seller's own page. The URL
    // rides a data attribute so the handler reads what was rendered rather than
    // a captured variable -- the pill is the one source of truth for where a
    // tap goes.
    // The seller's name as the native side gave it. It is the directory's own
    // display name, or the registrable domain -- but an empty one would render
    // as "$59.00 at " with nothing after it, so the URL's host stands in.
    function sellerPillName(sellerResp) {
        var name = (sellerResp.sellerName || "").trim();
        if (name) { return name; }
        try { return new URL(sellerResp.url).hostname.replace(/^www\./, ""); }
        catch (e) { return ""; }
    }

    function fillSellerPill(pill, sellerResp, stacked) {
        var label = localizedMessage("priceAtSeller")
            .replace("{price}", formatHistoryPrice(sellerResp.price, sellerResp.currency))
            .replace("{seller}", sellerPillName(sellerResp));
        while (pill.firstChild) { pill.removeChild(pill.firstChild); }
        pill.setAttribute("data-luna-state", "found");
        pill.setAttribute("data-luna-seller-url", sellerResp.url);
        pill.setAttribute("role", "button");
        pill.appendChild(document.createTextNode(label));
        applyStyle(pill, sellerPillStyle(stacked, true));
        pill.addEventListener("click", function () {
            var destination = pill.getAttribute("data-luna-seller-url");
            if (destination) { window.location.href = destination; }
        });
    }

    // Puts the page into the waiting state: the spinner pill, plus the Track
    // pill it stacks above (which is not waiting on anything and should not be
    // held back by this lookup). Returns whether the lookup may proceed.
    function beginSellerLookup(context, historyResp) {
        if (sellerLookupStarted) { return false; }
        if (!(context && context.supportsProducts)) { return false; }
        sellerLookupStarted = true;
        var isTracked = !!(historyResp && historyResp.isTracked);
        injectSellerSpinnerPill(!isTracked);
        if (!isTracked) {
            var trackTarget = trackTargetFor(context);
            if (trackTarget) { injectLunaButton(trackTarget); }
        }
        return true;
    }

    // An answer fills the pill in place. Anything else -- nothing found, a
    // failure, the backstop -- removes it and hands the page to today's rules
    // EXACTLY, `injectLunaButton`'s own id guard making the already-rendered
    // Track pill a no-op.
    function finishSellerLookup(context, historyResp, sellerResp) {
        var pill = document.getElementById(SELLER_PILL_ID);
        var isTracked = !!(historyResp && historyResp.isTracked);
        if (pill && sellerResp && sellerResp.found && sellerResp.url) {
            fillSellerPill(pill, sellerResp, !isTracked);
            return;
        }
        if (pill && pill.parentNode) { pill.parentNode.removeChild(pill); }
        renderProductPills(context, historyResp);
    }

    // For the WKWebView harness: the two halves of the lookup, observable
    // between them. See ProductHistoryPillRenderTests.
    window.__lunaBeginSellerLookup = beginSellerLookup;
    window.__lunaFinishSellerLookup = finishSellerLookup;
    window.__lunaRequestComparableSellers = requestComparableSellers;
    window.__lunaSellerPillID = SELLER_PILL_ID;

    // Extracts once, sends ONE `productSnapshot` message (recorded passively
    // AND answered against tracked/snapshot history in the same round trip --
    // see SharedProductSnapshots/SharedProductMatching), then asks for
    // alternative sellers before rendering. Falls back to the plain Track pill
    // when there's no browser host, no extraction, or the round trip fails.
    function handleProductPage(context) {
        var trackTarget = trackTargetFor(context);
        if (!(context && context.supportsProducts) || typeof browser === "undefined") {
            if (trackTarget) { injectLunaButton(trackTarget); }
            return;
        }
        var snapshot = extractProductSnapshot();
        if (!snapshot) {
            if (trackTarget) { injectLunaButton(trackTarget); }
            return;
        }
        browser.runtime.sendMessage({ type: "productSnapshot", snapshot: snapshot })
            .then(function (resp) {
                if (!beginSellerLookup(context, resp)) {
                    renderProductPills(context, resp);
                    return;
                }
                requestComparableSellers(snapshot).then(function (sellerResp) {
                    finishSellerLookup(context, resp, sellerResp);
                });
            })
            .catch(function () { renderProductPills(context, null); });
    }

    // ── The one-shot setup confirmation ─────────────────────────────────────────
    // The app's onboarding stamps the moment it sent the user to Safari; the native
    // handler stamps this extension's own first run and answers `celebrateSetup`
    // when both are within 24h and it has never confirmed before (the decision
    // lives in Swift — see SharedSafariURL.shouldCelebrateSetup). Here we only
    // render it, tell the native side it was seen, and hand the page back after
    // twenty seconds so it can read as a genuine completion state before a
    // pill can still appear if this page earns one. A document refresh tears
    // it down immediately rather than making it survive navigation.
    var SETUP_CELEBRATION_ID = "luna-setup-celebration";
    var SETUP_CELEBRATION_DURATION = 20000;

    function presentSetupCelebration(context, onDismiss) {
        if (document.getElementById(SETUP_CELEBRATION_ID)) { return; }
        var scheme = (context && context.scheme) || "";
        var appName = (context && context.appName) || "Luna";

        // Recorded HERE — committed to showing it, before a single node is built —
        // and deliberately not after the overlay lands. What follows is arbitrary DOM
        // work against an arbitrary page, and a one-shot whose flag is written last
        // is not one-shot at all when that work fails: the `$APP$` crash below cost
        // every page on the device, not one, precisely because the process died two
        // statements before this message was sent. The confirmation is worth one
        // page's chance; it is not worth an unbounded retry on all of them.
        if (typeof browser !== "undefined") {
            browser.runtime.sendMessage({ type: "setupCelebrationShown" }).catch(function () {});
        }

        // App chrome, not a save — so this one is coloured by the SURFACE this
        // extension belongs to rather than by any page kind.
        var tint = surfaceTint(context);

        var overlay = document.createElement("div");
        overlay.id = SETUP_CELEBRATION_ID;
        applyStyle(overlay, {
            position: "fixed", top: "0", left: "0", right: "0", bottom: "0",
            zIndex: "2147483647",
            // Semi-transparent so the page the extension just proved it can reach
            // stays visible behind the confirmation, tinted with the app's own
            // colour taken most of the way down toward the night sky — the tint
            // has to read as a wash over someone else's page, and three of the
            // four identity colours are far too bright to be one undimmed.
            background: tintRGBA(tintMixed(tint, "#0b0b10", 0.28), 0.85),
            webkitBackdropFilter: "blur(6px)", backdropFilter: "blur(6px)",
            boxSizing: "border-box", display: "flex", flexDirection: "column",
            alignItems: "center", justifyContent: "center", margin: "0",
            padding: "24px", overscrollBehavior: "contain"
        });

        // A third of the window, with the headline centred inside it — the button
        // sits directly below, and the pair is centred in the window as a whole.
        var headline = document.createElement("div");
        headline.appendChild(document.createTextNode(localizedMessage("setupCompleteTitle")));
        applyStyle(headline, {
            // A third of the WINDOW, not of the overlay's padded content box.
            flex: "0 0 33.3333vh", height: "33.3333vh", boxSizing: "border-box",
            display: "flex", alignItems: "center", justifyContent: "center",
            width: "100%", maxWidth: "20em", textAlign: "center",
            // `pre-line` renders the deliberate line break in the localized string.
            whiteSpace: "pre-line", color: "#ffffff",
            font: "700 clamp(28px, 8vw, 44px)/1.24 -apple-system, system-ui, sans-serif",
            // The page behind is arbitrary — dense black-on-white body text reads
            // straight through a semi-transparent scrim, so the headline carries
            // its own separation rather than relying on the tint alone.
            textShadow: "0 2px 18px rgba(0,0,0,0.55)",
            margin: "0", padding: "0"
        });
        // `dvh` follows Safari's collapsing toolbars where `vh` doesn't; assigning
        // an unsupported unit is a no-op, which leaves the `vh` values in place.
        headline.style.flexBasis = "33.3333dvh";
        headline.style.height = "33.3333dvh";
        overlay.appendChild(headline);

        var dismissed = false;
        var timer = null;
        var dismiss = function (runOnDismiss) {
            if (dismissed) { return; }
            dismissed = true;
            if (timer !== null) { clearTimeout(timer); timer = null; }
            if (overlay.parentNode) { overlay.parentNode.removeChild(overlay); }
            if (runOnDismiss && typeof onDismiss === "function") { onDismiss(); }
        };

        // No scheme means no app to return to (the handler always supplies one; a
        // failed native round trip does not) — the confirmation still stands, it
        // just carries no dead button.
        if (scheme) {
            var button = document.createElement("div");
            button.setAttribute("role", "button");
            button.appendChild(document.createTextNode(
                localizedMessage("returnToApp").replace("{app}", appName)));
            applyStyle(button, {
                boxSizing: "border-box", display: "inline-flex",
                alignItems: "center", justifyContent: "center", textAlign: "center",
                // The one filled control on a tinted wash, so it inverts: the
                // app's colour as the WORD on white, rather than a second wash.
                // Taken to its ink-dark mix when the raw tint would be too pale
                // to read on white (the Reader's periwinkle, the Tracker's green).
                background: "#ffffff", color: readableOnWhite(tint),
                font: "600 17px/1 -apple-system, system-ui, sans-serif",
                border: "none", borderRadius: "999px",
                padding: "16px 28px", minHeight: "44px", maxWidth: "100%",
                margin: "0", boxShadow: "0 8px 24px rgba(0,0,0,0.35)",
                cursor: "pointer", webkitTapHighlightColor: "transparent",
                touchAction: "manipulation", webkitAppearance: "none",
                appearance: "none"
            });
            button.addEventListener("click", function () {
                button.textContent = localizedMessage("openingLuna");
                button.style.opacity = "0.7";
                button.style.pointerEvents = "none";
                // Bare scheme, no payload: this reopens the app on whatever it was
                // showing, it does not hand it this page. Leaving the overlay up —
                // we're navigating away, and no pill belongs on a page being left.
                dismissed = true;
                if (timer !== null) { clearTimeout(timer); timer = null; }
                window.location.href = scheme + "://";
            });
            overlay.appendChild(button);
        }

        (document.body || document.documentElement).appendChild(overlay);
        // Refreshing replaces the document anyway, but explicitly dismissing
        // keeps the in-memory state honest during Safari's page-cache and
        // navigation transitions. Do not run the pill callback while leaving.
        window.addEventListener("pagehide", function () { dismiss(false); }, { once: true });
        timer = setTimeout(function () { dismiss(true); }, SETUP_CELEBRATION_DURATION);
    }

    // For the WKWebView harnesses, which have no extension host — see
    // SafariSetupCelebrationTests.
    window.__lunaPresentSetupCelebration = presentSetupCelebration;
    window.__lunaSetupCelebrationID = SETUP_CELEBRATION_ID;
    window.__lunaSetupCelebrationDuration = SETUP_CELEBRATION_DURATION;

    // ── The in-page video player ────────────────────────────────────────────────
    // On a media host (the central Luna app / Luna Downloader), a recognized post
    // page opens a player right here instead of navigating: the native handler
    // runs the app's own resolver over this post URL and hands back a direct CDN
    // URL, which a plain <video> streams. The page's own CSP governs that load,
    // which is why this only ever plays a SAME-PLATFORM asset — instagram.com
    // allows *.cdninstagram.com, x.com allows *.twimg.com, and so on.
    //
    // Nothing here decides WHAT is playable: the handler answers with the assets
    // `MediaAsset.isDirectlyPlayable` accepted, and an empty answer — for any
    // reason at all — falls back to the hand-off this pill used to do.
    var VIDEO_OVERLAY_ID = "luna-video-overlay";
    // Longer than the handler's own 20s budget, so a native side that answers
    // late still wins over this backstop and only a DEAD one trips it.
    var RESOLVE_TIMEOUT = 25000;
    var NIGHT_SURFACE = "#0b0b10";
    // When the auto-open looks for the page's video, counted from the moment the
    // pill lands (document_idle). A client-rendered post frequently has neither
    // its `<video>` nor its video metadata yet at that point, and giving up on
    // the first look is what would make the player feel unreliable rather than
    // automatic. The walk stops at the first look that finds a signal.
    var AUTO_PLAYER_RETRY_DELAYS = [0, 900, 2500];
    // The stage's FLOOR, and the shape it opens at: the 16:9 this panel has
    // always been. A wide clip therefore gets exactly the panel that shipped;
    // only a taller-than-16:9 one grows the popup.
    var PLAYER_MIN_ASPECT = 9 / 16;
    // How much of the visible page the grown panel may take. It stops short of
    // the whole of it in both directions so the page it is over still frames it.
    var PLAYER_VIEWPORT_INSET = 14;
    // How long the panel takes to CORRECT its height — a rotation, a toolbar
    // collapsing, a second opinion about the clip's shape. Learning the shape in
    // the first place is not a correction and never animates (see
    // `setStageAspect`). Writable so a test can assert on a settled layout
    // instead of waiting one out.
    var PLAYER_GROWTH_SECONDS = 0.24;
    window.__lunaSetPlayerGrowthSeconds = function (value) { PLAYER_GROWTH_SECONDS = value; };
    // How long after the panel opens a shape still counts as the panel ARRIVING
    // at its size (applied with no animation) rather than changing size in front
    // of the user (animated). Long enough to cover the resolve round trip and
    // the first metadata callback, short enough that a shape which only turns up
    // when the user presses Play settles instead of snapping.
    var PLAYER_INSTANT_SIZING_MS = 700;
    // A dismissal is the user saying "not this page": it stops any auto-open
    // still pending. The PILL is unaffected — tapping it re-opens the player.
    var videoOverlayDismissed = false;

    // The native round trip, behind a swappable reference: the WKWebView test
    // harness has no extension host at all (`browser` is undefined), so
    // SafariVideoOverlayTests substitutes its own resolver here.
    var resolveMediaRequest = function (url, title) {
        if (typeof browser === "undefined") { return Promise.resolve({ assets: [] }); }
        return browser.runtime.sendMessage({ type: "resolveMedia", url: url, title: title });
    };
    window.__lunaSetResolveMediaRequest = function (fn) { resolveMediaRequest = fn; };

    /// Resolves to the reply, or to an empty result if the native side never
    /// answers — a promise that never settles would leave the player spinning
    /// with no way out.
    function requestResolvedMedia(url, title) {
        return new Promise(function (resolve) {
            var settled = false;
            var finish = function (result) {
                if (settled) { return; }
                settled = true;
                resolve(result && Array.isArray(result.assets) ? result : { assets: [] });
            };
            setTimeout(function () { finish(null); }, RESOLVE_TIMEOUT);
            try {
                resolveMediaRequest(url, title).then(finish, function () { finish(null); });
            } catch (e) {
                finish(null);
            }
        });
    }

    /// What the user can actually SEE, in CSS px — not the screen, and not the
    /// layout viewport either.
    ///
    /// Both of the obvious answers are wrong here. `100vh` is the LARGE viewport
    /// (as though Safari's toolbars were retracted), so a panel measured against
    /// it runs under the address bar. And `position: fixed` is laid out against
    /// the layout viewport, which is that same tall box — so the backdrop's own
    /// height is no better an answer than `100vh` is. `visualViewport` is the one
    /// thing that reports the box that is on screen right now, toolbars and all;
    /// the safe-area insets are then subtracted from it as PADDING (below), since
    /// they describe the unsafe part of exactly that box.
    function visiblePageBox() {
        var viewport = window.visualViewport;
        if (viewport && viewport.height > 0) {
            return { top: viewport.offsetTop || 0, height: viewport.height };
        }
        var fallback = window.innerHeight || document.documentElement.clientHeight || 0;
        return { top: 0, height: fallback };
    }
    window.__lunaVisiblePageBox = visiblePageBox;

    /// The clip's height ÷ width as the PAGE already knows it, or 0.
    ///
    /// Worth asking before the stream opens because it costs nothing and lands a
    /// beat earlier than `loadedmetadata` — but it is only ever an optimisation:
    /// most posts declare no video dimensions, and the element's own metadata
    /// overrides whatever this says the moment it arrives. `exclude` keeps our
    /// own panel out of the DOM walk.
    ///
    /// Three sources, strongest first. The last of them is the poster's shape
    /// rather than the video's, and it is here because of Instagram: a reel
    /// declares no video whatsoever, and its `og:image` cover is generated at the
    /// clip's own aspect. A cover that lies costs one animated correction when
    /// the real metadata lands; having nothing at all costs the panel opening
    /// letterboxed and jumping.
    function pageMediaAspect(exclude) {
        var pairs = [
            ["og:video:width", "og:video:height"],
            ["twitter:player:width", "twitter:player:height"]
        ];
        for (var i = 0; i < pairs.length; i++) {
            var width = metaNumber(pairs[i][0]);
            var height = metaNumber(pairs[i][1]);
            if (width > 0 && height > 0) { return height / width; }
        }
        var existing = document.querySelectorAll("video");
        for (var j = 0; j < existing.length; j++) {
            var element = existing[j];
            if (exclude && exclude.contains(element)) { continue; }
            if (element.videoWidth > 0 && element.videoHeight > 0) {
                return element.videoHeight / element.videoWidth;
            }
        }
        var coverWidth = metaNumber("og:image:width");
        var coverHeight = metaNumber("og:image:height");
        if (coverWidth > 0 && coverHeight > 0) { return coverHeight / coverWidth; }
        return 0;
    }

    /// A `<meta>` value as a number, under either the `property` (Open Graph) or
    /// the `name` (Twitter card) spelling. 0 when absent or not a number.
    function metaNumber(key) {
        var node = document.querySelector('meta[property="' + key + '"]')
            || document.querySelector('meta[name="' + key + '"]');
        var value = node && parseFloat(node.getAttribute("content"));
        return value > 0 ? value : 0;
    }

    function presentVideoOverlay(context, handoff) {
        if (document.getElementById(VIDEO_OVERLAY_ID)) { return; }
        var sourceURL = location.href;
        var tint = (handoff && handoff.tint) || KIND_TINTS.media;

        var backdrop = document.createElement("div");
        backdrop.id = VIDEO_OVERLAY_ID;
        applyStyle(backdrop, {
            position: "fixed", top: "0", left: "0", right: "0", bottom: "0",
            zIndex: "2147483647", background: "rgba(0, 0, 0, 0.78)",
            webkitBackdropFilter: "blur(4px)", backdropFilter: "blur(4px)",
            boxSizing: "border-box", display: "flex", flexDirection: "column",
            alignItems: "center", justifyContent: "center", margin: "0",
            // The inset the panel is allowed to grow into, plus whatever of this
            // box the system says is unsafe. On an ordinary page both insets
            // resolve to 0 and this is the padding it always had; on a
            // `viewport-fit=cover` page they are the notch and the home
            // indicator, which `visualViewport` includes and nothing should
            // render under.
            paddingTop: "calc(" + PLAYER_VIEWPORT_INSET + "px + env(safe-area-inset-top))",
            paddingBottom: "calc(" + PLAYER_VIEWPORT_INSET + "px + env(safe-area-inset-bottom))",
            paddingLeft: "12px", paddingRight: "12px",
            overscrollBehavior: "contain"
        });

        // Near the full width, and only as tall as what's in it.
        var panel = document.createElement("div");
        applyStyle(panel, {
            boxSizing: "border-box", width: "calc(100vw - 24px)", maxWidth: "640px",
            height: "auto", background: NIGHT_SURFACE, borderRadius: "20px",
            border: "none", margin: "0", padding: "10px",
            display: "flex", flexDirection: "column", alignItems: "stretch",
            boxShadow: "0 24px 60px rgba(0,0,0,0.55)"
        });
        // A tap inside the panel is not a tap on the backdrop.
        panel.addEventListener("click", function (event) { event.stopPropagation(); });

        var header = document.createElement("div");
        applyStyle(header, {
            boxSizing: "border-box", display: "flex", justifyContent: "flex-start",
            alignItems: "center", margin: "0", padding: "0 0 8px 0"
        });

        var close = document.createElement("div");
        close.setAttribute("role", "button");
        close.setAttribute("aria-label", localizedMessage("closeVideo"));
        close.appendChild(document.createTextNode("✕"));
        applyStyle(close, {
            boxSizing: "border-box", display: "inline-flex",
            alignItems: "center", justifyContent: "center",
            width: "34px", height: "34px", minHeight: "0",
            borderRadius: "999px", border: "none",
            background: "rgba(255,255,255,0.12)", color: "#ffffff",
            font: "500 17px/1 -apple-system, system-ui, sans-serif",
            margin: "0", padding: "0", cursor: "pointer",
            webkitTapHighlightColor: "transparent", touchAction: "manipulation",
            webkitAppearance: "none", appearance: "none"
        });
        header.appendChild(close);
        panel.appendChild(header);

        // The stage opens at 16:9 and is the ONLY part of the panel that ever
        // changes size — swapping the status line for the player (or for the
        // failure message) still doesn't resize anything under the user's thumb.
        // What does resize it is learning the clip's real shape: see
        // `setStageAspect`, which is the whole of the popup's height.
        var stage = document.createElement("div");
        applyStyle(stage, {
            boxSizing: "border-box", position: "relative", width: "100%",
            aspectRatio: "16 / 9", background: "#000000", borderRadius: "12px",
            overflow: "hidden", margin: "0", padding: "0",
            display: "flex", alignItems: "center", justifyContent: "center"
        });
        panel.appendChild(stage);

        var status = document.createElement("div");
        status.appendChild(document.createTextNode(localizedMessage("findingVideo")));
        applyStyle(status, {
            boxSizing: "border-box", color: "rgba(255,255,255,0.72)", textAlign: "center",
            font: "500 15px/1.3 -apple-system, system-ui, sans-serif",
            margin: "0", padding: "0 16px"
        });
        stage.appendChild(status);

        var download = document.createElement("div");
        download.setAttribute("role", "button");
        download.appendChild(document.createTextNode(localizedMessage("downloadInLuna")));
        applyStyle(download, {
            boxSizing: "border-box", display: "inline-flex",
            alignItems: "center", justifyContent: "center", whiteSpace: "nowrap",
            // The same tint the pill that opened this panel carries.
            background: tint, color: tintForeground(tint),
            font: "600 16px/1 -apple-system, system-ui, sans-serif",
            border: "none", borderRadius: "999px",
            minHeight: "44px", height: "auto", width: "100%",
            margin: "10px 0 0 0", padding: "13px 22px",
            cursor: "pointer", webkitTapHighlightColor: "transparent",
            touchAction: "manipulation", webkitAppearance: "none", appearance: "none"
        });
        panel.appendChild(download);

        backdrop.appendChild(panel);

        var video = null;
        var closed = false;
        var didResolve = false;

        // ── The popup's height ──────────────────────────────────────────────
        // A 9:16 reel in a 16:9 letterbox is mostly black bars, so the stage
        // takes the clip's own shape — clamped at BOTH ends. It never goes below
        // the 16:9 it opens at (a wide clip keeps the panel exactly as it was),
        // and never past what `visiblePageBox` says is on screen.
        var stageAspect = 0;
        // Whether the shape came from the media itself rather than from
        // something the page said about its cover — see `setStageAspect`.
        var hasAuthoritativeAspect = false;
        // When the panel appeared, which is what separates "opening at the right
        // size" from "changing size while someone is looking at it".
        var openedAt = Date.now();

        /// Everything in the panel that is not the stage: its padding, the header
        /// and the download button. Measured rather than added up from the
        /// constants above, so a wrapped button label or a large accessibility
        /// font is already accounted for in what's left over for the stage.
        var panelChromeHeight = function () {
            return Math.max(0, panel.offsetHeight - stage.offsetHeight);
        };

        /// The tallest the stage may be and still leave the whole panel inside
        /// the visible box, insets and all.
        var stageCeiling = function () {
            var box = visiblePageBox();
            var style = window.getComputedStyle(backdrop);
            var padding = (parseFloat(style.paddingTop) || 0)
                + (parseFloat(style.paddingBottom) || 0);
            return box.height - padding - panelChromeHeight();
        };

        // The backdrop is `position: fixed`, so it covers the LAYOUT viewport —
        // taller than what's on screen, and centring in it puts the panel behind
        // Safari's toolbar. Pin it to the visible box instead, and the flex
        // centring inside it is then centring in what the user can see.
        var layoutBackdrop = function () {
            var box = visiblePageBox();
            if (!(box.height > 0)) { return; }
            backdrop.style.top = box.top + "px";
            backdrop.style.bottom = "auto";
            backdrop.style.height = box.height + "px";
        };

        var applyStageHeight = function () {
            var width = stage.clientWidth;
            if (!(width > 0)) { return; }
            var floor = width * PLAYER_MIN_ASPECT;
            var wanted = stageAspect > 0 ? width * stageAspect : floor;
            // The floor wins over the ceiling, not the other way round: a landscape
            // phone has less room than 16:9 needs, and shrinking the stage there
            // would make the panel smaller than the one this feature shipped with.
            var height = Math.min(Math.max(wanted, floor), Math.max(floor, stageCeiling()));
            // An explicit height overrides the opening `aspect-ratio`; clearing it
            // keeps the two from arguing about the same box.
            stage.style.aspectRatio = "auto";
            stage.style.height = Math.round(height) + "px";
        };

        /// `ratio` is the clip's height ÷ width. Ignored unless it actually says
        /// something new, so a repeated `loadedmetadata` costs no layout.
        ///
        /// `authoritative` is the element's own metadata (or the resolver's
        /// declared rendition size) rather than something the page implied about
        /// its cover image. A guess may replace another guess, but never an
        /// answer — otherwise a poster that decodes late would re-shape a panel
        /// already sized by the stream.
        var setStageAspect = function (ratio, authoritative) {
            if (!(ratio > 0) || Math.abs(ratio - stageAspect) < 0.005) { return; }
            if (hasAuthoritativeAspect && !authoritative) { return; }
            if (authoritative) { hasAuthoritativeAspect = true; }
            // LEARNING the shape is the panel arriving at its size and must not
            // animate: it lands within a few hundred ms of the panel opening,
            // while the stage still says "Finding video…", and a transition there
            // is only a way for the first paint to be the wrong size. Changing
            // its mind afterwards is a correction, and that one has to be a
            // movement — the panel is already something the user is looking at.
            //
            // The same is true of a FIRST shape that arrives late. A platform
            // that declares nothing anywhere can leave the answer to the stream,
            // and on iOS the stream can wait for the Play tap — at which point
            // an unanimated resize is the panel snapping under the user's thumb,
            // which is the one thing the sizing is here to avoid. So the
            // no-animation case is not "the first" shape, it is "a shape that
            // arrived while the panel was still appearing".
            var isArrival = stageAspect === 0
                && (Date.now() - openedAt) < PLAYER_INSTANT_SIZING_MS;
            if (!isArrival) {
                stage.style.transition = "height " + PLAYER_GROWTH_SECONDS + "s ease";
            }
            stageAspect = ratio;
            applyStageHeight();
        };

        // A toolbar collapsing, a rotation, or a pinch all change the visible box
        // under a panel that is already up. `scroll` only ever moves it (cheap,
        // writes only); `resize` may also change how much room the stage has.
        var onViewportScroll = function () { if (!closed) { layoutBackdrop(); } };
        var onViewportResize = function () {
            if (closed) { return; }
            layoutBackdrop();
            applyStageHeight();
        };

        // Every platform this pill appears on autoplays its own player, and that
        // player keeps running behind an overlay — two videos, two soundtracks.
        // Pause the page's, remember exactly which ones WE paused, and put them
        // back on dismiss; a video the user had already paused stays paused.
        var pausedByOverlay = [];
        var pausePageVideos = function () {
            var existing = document.querySelectorAll("video");
            for (var i = 0; i < existing.length; i++) {
                var element = existing[i];
                if (element.paused) { continue; }
                try { element.pause(); pausedByOverlay.push(element); } catch (e) {}
            }
        };
        var resumePageVideos = function () {
            for (var i = 0; i < pausedByOverlay.length; i++) {
                // A play() this far from a user gesture can be refused; it
                // returns a rejecting promise rather than throwing, so both.
                try {
                    var resumed = pausedByOverlay[i].play();
                    if (resumed && resumed.catch) { resumed.catch(function () {}); }
                } catch (e) {}
            }
            pausedByOverlay = [];
        };

        // The player opens BEFORE the page's own has necessarily been created —
        // an autoplaying post whose `<video>` hydrates a second later would
        // otherwise start playing, unmuted, behind the panel. So the pause is not
        // a one-shot sweep: for as long as the panel is up, anything that starts
        // playing outside it is paused (and remembered) the moment it does.
        var pageVideoPlayGuard = function (event) {
            var element = event.target;
            if (!element || element.tagName !== "VIDEO") { return; }
            if (backdrop.contains(element)) { return; }
            try { element.pause(); } catch (e) {}
            if (pausedByOverlay.indexOf(element) < 0) { pausedByOverlay.push(element); }
        };

        var dismiss = function () {
            if (closed) { return; }
            closed = true;
            videoOverlayDismissed = true;
            document.removeEventListener("play", pageVideoPlayGuard, true);
            if (window.visualViewport) {
                window.visualViewport.removeEventListener("scroll", onViewportScroll);
                window.visualViewport.removeEventListener("resize", onViewportResize);
            }
            window.removeEventListener("orientationchange", onViewportResize);
            if (video) {
                try { video.pause(); } catch (e) {}
                video.removeAttribute("src");
                try { video.load(); } catch (e) {}
            }
            if (backdrop.parentNode) { backdrop.parentNode.removeChild(backdrop); }
            resumePageVideos();
        };
        backdrop.addEventListener("click", dismiss);
        close.addEventListener("click", dismiss);

        // The stage failed (or never resolved): keep the panel, say so, and let
        // Download do exactly what the pill did before this feature existed.
        var degrade = function () {
            didResolve = false;
            if (video && video.parentNode) { video.parentNode.removeChild(video); }
            video = null;
            status.textContent = localizedMessage("videoUnplayable");
            if (!status.parentNode) { stage.appendChild(status); }
        };

        download.addEventListener("click", function () {
            download.textContent = localizedMessage("openingLuna");
            download.style.opacity = "0.7";
            download.style.pointerEvents = "none";
            if (video) { try { video.pause(); } catch (e) {} }
            // Resolved: the handler already holds the assets, so the app is sent
            // a payload-free link and drains them itself. Not resolved: the
            // original hand-off, which makes the app do the whole job.
            if (!didResolve) {
                window.location.href = handoff.url();
                return;
            }
            var open = function () { window.location.href = resolvedMediaTarget(context); };
            if (typeof browser === "undefined") { open(); return; }
            browser.runtime.sendMessage({ type: "queueResolvedDownload", url: sourceURL })
                .then(function (resp) {
                    if (resp && resp.queued) { open(); } else { window.location.href = handoff.url(); }
                })
                .catch(function () { window.location.href = handoff.url(); });
        });

        // Before our own <video> exists, so this only ever reaches the page's.
        pausePageVideos();
        // `play` does not bubble; a capture listener on the document still sees
        // every one of them.
        document.addEventListener("play", pageVideoPlayGuard, true);
        (document.body || document.documentElement).appendChild(backdrop);

        // In the document, so everything below can measure. The clip's shape is
        // taken from the page if the page happens to know it — most don't, and an
        // Instagram reel carries no video metadata at all — and corrected the
        // moment our own element reports the real thing.
        layoutBackdrop();
        setStageAspect(pageMediaAspect(backdrop));
        if (window.visualViewport) {
            window.visualViewport.addEventListener("scroll", onViewportScroll);
            window.visualViewport.addEventListener("resize", onViewportResize);
        }
        window.addEventListener("orientationchange", onViewportResize);

        requestResolvedMedia(sourceURL, document.title || "").then(function (result) {
            if (closed) { return; }
            var asset = (result.assets || [])[0];
            if (!asset || !asset.url) { degrade(); return; }
            didResolve = true;
            // The resolve itself often knows the rendition's size (the CDN names
            // it in the URL — `MediaAsset.declaredPixelSize`), and it lands a
            // whole network round trip before the element's metadata does. It is
            // the media's own size, not a guess about it, so it counts as the
            // answer.
            if (asset.width > 0 && asset.height > 0) {
                setStageAspect(asset.height / asset.width, true);
            }
            if (status.parentNode) { status.parentNode.removeChild(status); }
            video = document.createElement("video");
            video.setAttribute("controls", "");
            video.setAttribute("playsinline", "");
            video.setAttribute("webkit-playsinline", "");
            video.setAttribute("preload", "metadata");
            if (asset.thumbnailURL) { video.setAttribute("poster", asset.thumbnailURL); }
            applyStyle(video, {
                boxSizing: "border-box", display: "block", width: "100%", height: "100%",
                objectFit: "contain", background: "#000000", margin: "0", padding: "0",
                border: "none", borderRadius: "0"
            });
            // The authority on the clip's shape. We ask before playback below,
            // then repeat the read across Safari's readiness signals.
            var applyVideoAspect = function () {
                if (closed || !video) { return; }
                if (video.videoWidth > 0 && video.videoHeight > 0) {
                    setStageAspect(video.videoHeight / video.videoWidth, true);
                }
            };
            // Nothing has said anything about the shape yet, and the stream may
            // not either until the user presses Play (iOS defers metadata for an
            // off-page player). The poster is already being fetched to fill the
            // stage — decoding it costs nothing extra and is usually the clip's
            // own shape. A guess, so the stream still overrides it.
            if (asset.thumbnailURL && stageAspect === 0) {
                var cover = new Image();
                cover.addEventListener("load", function () {
                    if (closed || !(cover.naturalWidth > 0)) { return; }
                    setStageAspect(cover.naturalHeight / cover.naturalWidth, false);
                });
                cover.src = asset.thumbnailURL;
            }
            // iOS can defer `loadedmetadata` for an off-main-page player until a
            // user gesture, and a restored page can race past that one event.
            // Every subsequent readiness/playback signal repeats the cheap size
            // read, while `setStageAspect` discards duplicates.
            ["loadedmetadata", "loadeddata", "canplay", "durationchange", "playing"]
                .forEach(function (eventName) {
                    video.addEventListener(eventName, applyVideoAspect);
                });
            // The page's CSP has the last word on the media load, and an expired
            // googlevideo URL 403s — either way the element reports it here.
            video.addEventListener("error", function () { if (!closed) { degrade(); } }, true);
            video.setAttribute("src", asset.url);
            stage.appendChild(video);
            // `preload=metadata` is advisory on iOS. An explicit load starts the
            // metadata request now, before Download or Play provides a gesture.
            try { video.load(); } catch (e) {}
            applyVideoAspect();
        });
    }

    /// Opens the player without being asked, on a recognized post page whose
    /// subject IS a video — the pill is then how the user gets back to it.
    ///
    /// This asks a NARROWER question than pill eligibility, and deliberately: a
    /// bare platform host recognizes (`x.com/home`, `tiktok.com`), and a feed
    /// that slips past the static-image suppression may earn a pill, but covering
    /// someone's feed with a panel they did not ask for is a different thing from
    /// offering them a button beside it. It takes the same two authorities
    /// `shouldShowDownloadPillForPlatform` takes, in the same order:
    ///
    ///  1. the URL SHAPE, where a platform has video-only surfaces
    ///     (`pathIsInherentlyVideo`). This is load-bearing rather than an
    ///     optimisation — an Instagram reel carries NO video metadata at all
    ///     (`og:type` is "article", the only media meta is a JPG) and hydrates
    ///     its `<video>` well after this file runs, so waiting for a signal
    ///     there would mean waiting for one that never comes.
    ///  2. otherwise the video signal — `og:video` / player metadata / a
    ///     `<video>` / a GIF — looked for again on a short bounded schedule,
    ///     since a client-rendered post often has none of it yet at
    ///     `document_idle`.
    function autoPresentVideoOverlay(platform, target, attempt) {
        if (videoOverlayDismissed) { return; }
        if (document.getElementById(VIDEO_OVERLAY_ID)) { return; }
        if (pathIsInherentlyVideo(platform) || hasVideoOrAnimatedImageSignal()) {
            target.present();
            return;
        }
        var next = attempt + 1;
        if (next >= AUTO_PLAYER_RETRY_DELAYS.length) { return; }
        setTimeout(function () { autoPresentVideoOverlay(platform, target, next); },
                   AUTO_PLAYER_RETRY_DELAYS[next]);
    }

    /// `<scheme>://resolvedmedia?ret=safari` — a payload-free hand-off, exactly
    /// like `rescue`: the assets are already in the App Group, so the app drains
    /// them and bounces back here (`SafariReturnPolicy`).
    function resolvedMediaTarget(context) {
        var scheme = (context && context.scheme) || "";
        return scheme + "://resolvedmedia?ret=safari";
    }

    // For the WKWebView harness (no extension host) — see SafariVideoOverlayTests.
    window.__lunaPresentVideoOverlay = presentVideoOverlay;
    window.__lunaVideoOverlayID = VIDEO_OVERLAY_ID;
    window.__lunaAutoPlayerRetryDelays = AUTO_PLAYER_RETRY_DELAYS;
    window.__lunaInstantSizingMilliseconds = PLAYER_INSTANT_SIZING_MS;

    var PILL_ID = "queue-read-button";
    window.__lunaPillID = PILL_ID;

    function injectLunaButton(target) {
        if (document.getElementById(PILL_ID)) { return; }
        // A <div role="button"> (not a <button>) so the host page's `button {…}`
        // CSS can't clamp its height and cut off the pill. Explicit resets +
        // inline-flex centering + a fully-rounded radius guarantee the pill shape.
        var btn = document.createElement("div");
        btn.id = PILL_ID;
        btn.setAttribute("role", "button");
        btn.appendChild(document.createTextNode(target.label));
        // The kind's own colour (see KIND_TINTS) — a target that names none is
        // not a save, so it falls back to the central app's indigo.
        var tint = target.tint || QUEUE_INDIGO;
        btn.setAttribute("data-luna-tint", tint);
        applyStyle(btn, {
            position: "fixed", right: "16px",
            bottom: "calc(20px + env(safe-area-inset-bottom))",
            zIndex: "2147483647", background: tint, color: tintForeground(tint),
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
            // A target that presents something in-page (the video player) stays
            // here: no navigation, and the pill keeps its label so it still
            // reads correctly behind the overlay when that overlay is dismissed.
            if (typeof target.present === "function") {
                target.present();
                return;
            }
            btn.textContent = target.pressedLabel
                || localizedMessage("openingLuna");
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
            label: localizedMessage("readInLuna"),
            tint: KIND_TINTS.article,
            captureContent: true,
            url: function () { return ownSchemeTarget(context, location.href); }
        };
    }

    // Only media pill taps bounce the user back to Safari once the app has
    // started the background download: its Live Activity keeps progress visible
    // there. Article and product cards are the hand-off destination, so neither
    // carries `&ret=safari`. The flag rides the deep link rather than a separate
    // message so it survives when `saveContent` isn't sent (downloadTargetFor
    // never captures content).
    function downloadTargetFor(context) {
        if (!(context && context.supportsMedia)) { return null; }
        return {
            label: localizedMessage("downloadInLuna"),
            tint: KIND_TINTS.media,
            captureContent: false,
            url: function () { return ownSchemeTarget(context, location.href) + "&ret=safari"; }
        };
    }

    // The same pill, tapped to open the in-page player instead of leaving for
    // the app — with `downloadTargetFor`'s hand-off carried along as the
    // fallback the overlay uses when nothing turns out to be playable.
    //
    // Reddit deliberately does NOT come through here (see `handleReddit`): its
    // video and audio are separate DASH streams, so there is nothing a single
    // <video> can play, and its pill keeps the plain hand-off it has today.
    function videoOverlayTargetFor(context) {
        var handoff = downloadTargetFor(context);
        if (!handoff) { return null; }
        // The user can turn the player off (Settings → Safari, media apps only).
        // The native handler answers `videoPlayer: false` then, and the pill goes
        // back to being the plain hand-off it was before the player existed —
        // same label, same tint, same deep link, no panel over their page.
        if (context && context.videoPlayer === false) { return handoff; }
        return {
            label: handoff.label,
            tint: handoff.tint,
            captureContent: false,
            url: handoff.url,
            present: function () { presentVideoOverlay(context, handoff); }
        };
    }

    // The "Track in Luna" button target for a recognized product page. Sends
    // the rendered DOM (`captureContent: true`) so the app's product save runs
    // over prefetched, hydrated HTML -- fast, and client-rendered prices
    // resolve without a WebView render tier -- exactly as the article pill
    // already does.
    function trackTargetFor(context) {
        if (!(context && context.supportsProducts)) { return null; }
        return {
            label: localizedMessage("trackInLuna"),
            tint: KIND_TINTS.product,
            captureContent: true,
            url: function () { return ownSchemeTarget(context, location.href); }
        };
    }


    // For the WKWebView harnesses (no extension host), which drive the real
    // targets rather than hand-building one — see SafariSurfaceTintTests.
    window.__lunaInjectLunaButton = injectLunaButton;
    window.__lunaReadTarget = readTarget;
    window.__lunaDownloadTarget = downloadTargetFor;
    window.__lunaTrackTarget = trackTargetFor;

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
        if (pathIsInherentlyVideo(platform)) { return true; }
        return !looksLikeStaticImagePost();
    }

    // Surfaces whose URL SHAPE alone settles it: the page can only ever be a
    // video, so the meta-tag heuristics below must not get a vote.
    //
    // This exists because Instagram serves a reel exactly the way it serves a
    // photo post — `og:type` is literally "article", the only media meta is the
    // JPG thumbnail, and there is no `og:video` / `twitter:player` anywhere in
    // the document (verified against a live reel: the word "mp4" does not occur
    // in the served HTML at all). Its <video> is hydrated by script well after
    // this file runs, so `hasStaticImagePostSignal` matched and every reel lost
    // its pill — while the same link, shared into the Downloader, downloaded
    // fine. `/reel/`, `/reels/` and `/tv/` are video-only surfaces, so the path
    // is the signal. `/p/` deliberately stays on the heuristics: it carries both
    // photos and videos, and only a static-image verdict there is correct.
    //
    // Path shapes mirror PlatformRecognizer.instagram's media kinds — a leading
    // username segment is allowed (`/<user>/reel/<code>/`, which is what
    // Instagram's own og:url uses).
    var INHERENTLY_VIDEO_PATH_SEGMENTS = {
        instagram: ["reel", "reels", "tv"]
    };

    function pathIsInherentlyVideo(platform) {
        var kinds = INHERENTLY_VIDEO_PATH_SEGMENTS[platform];
        if (!kinds) { return false; }
        var segments = location.pathname.split("/").filter(function (s) { return s.length > 0; });
        for (var i = 0; i < segments.length - 1; i++) {
            if (kinds.indexOf(segments[i].toLowerCase()) >= 0) {
                return !!nonEmptySegment(segments[i + 1]);
            }
        }
        return false;
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
        var existing = document.getElementById(PILL_ID);
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
