// Luna Safari content script. Injects a Luna button on article pages (per the
// app's visibility setting) or known Downloader-platform pages. Article taps
// deep-link into the reader; platform taps open the Downloader app/clip.

(function () {
    "use strict";

    // The background script injects this via scripting.executeScript, which can
    // fire more than once per document — run our setup only the first time.
    if (window.__queueContentScriptRan) { return; }
    window.__queueContentScriptRan = true;

    var QUEUE_INDIGO = "#5856D6";

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

    browser.runtime.sendMessage({ type: "buttonContext" }).then(function (resp) {
        var mode = (resp && resp.mode) || "all";
        if (mode === "never") { return; }
        var platform = recognizedPlatformPage();
        if (platform) {
            var downloadTarget = downloadTargetFor(resp);
            if (downloadTarget) { injectLunaButton(downloadTarget); }
            return;
        }
        if (!looksLikeArticle()) { return; }
        if (mode === "onlyLocked" && !looksPaywalled()) { return; }
        injectLunaButton(readTarget(resp));
    }).catch(function () {});

    // When the "Unlock Paywalls On-Device" toggle is on, reveal the body in Safari
    // (the Referer rewrite that unlocks the server response is applied declaratively
    // by the background ruleset; this strips the leftover overlay/clamp so the reader
    // — and the user, right here in Safari — sees the full article).
    browser.runtime.sendMessage({ type: "bypassEnabled" }).then(function (resp) {
        if (resp && resp.enabled) { revealArticle(); }
    }).catch(function () {});

    // Generic paywall-overlay cleanup (mirrors the app's browser-tier cleanup): remove
    // common overlay containers, un-blur/un-clamp the body, restore scroll, un-lazy
    // images. Re-runs briefly to cover late hydration.
    function revealArticle() {
        var REMOVE = [
            "div.paywall", "div.paywall-content", "div.meteredContent", "div#full-paywall",
            "aside#paywall", "div.subscription-wall", "div#tp-regwall", "div#tp-modal",
            "div.snippet-promotion", ".snippet-promotion", 'div[id*="-snippet-overlay"]',
            "div.modal-backdrop", 'div[class*="subscribe-wall"]', 'div[class*="regwall"]',
            "div.tp-modal", 'div[data-testid*="paywall"]', 'div[class*="PaywallOverlay"]',
            "div.piano-template"
        ];
        var UNHIDE = ["blurred", "blur", "gradient", "fade", "faded-content", "clipped",
            "cropped", "truncated", "locked", "is-locked", "noscroll", "no-scroll",
            "scroll-lock", "overflow-hidden", "modal-open"];
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
            } catch (e) {}
        }
        clean();
        var n = 0;
        var t = setInterval(function () { clean(); if (++n > 10) { clearInterval(t); } }, 600);
    }

    // A page worth a "Read in Luna" button: an article, not a homepage/search.
    function looksLikeArticle() {
        var ogType = document.querySelector('meta[property="og:type"]');
        if (ogType && /article/i.test(ogType.getAttribute("content") || "")) { return true; }
        if (document.querySelector("article")) { return true; }
        var paragraphs = document.querySelectorAll("p");
        var textLength = 0;
        for (var i = 0; i < paragraphs.length; i++) {
            textLength += (paragraphs[i].innerText || "").length;
        }
        return textLength > 1500 && !!document.querySelector("h1");
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
            btn.textContent = "Opening Luna…";
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

    function readTarget(context) {
        var appClipBaseURL = context && (context.readerAppClipURL || "");
        return {
            label: "📖  Read in Luna",
            captureContent: true,
            url: function () {
                if (appClipBaseURL) { return urlWithSource(appClipBaseURL, location.href); }
                // Pre-submission fallback: a tap is a user gesture, so Safari allows
                // the custom-scheme launch when the Reader app is installed.
                return "lunareader://read?url=" + encodeURIComponent(location.href);
            }
        };
    }

    function downloadTargetFor(context) {
        if (context && context.isDownloaderHost) {
            return {
                label: "Download in Luna",
                captureContent: false,
                url: function () {
                    return "lunareader://read?url=" + encodeURIComponent(location.href);
                }
            };
        }
        var appClipBaseURL = context && (context.downloaderAppClipURL || "");
        if (!appClipBaseURL) { return null; }
        return {
            label: "Download in Luna",
            captureContent: false,
            url: function () { return urlWithSource(appClipBaseURL, location.href); }
        };
    }

    function urlWithSource(baseURL, sourceURL) {
        try {
            var url = new URL(baseURL);
            url.searchParams.set("url", sourceURL);
            return url.toString();
        } catch (e) {
            var join = baseURL.indexOf("?") >= 0 ? "&" : "?";
            return baseURL + join + "url=" + encodeURIComponent(sourceURL);
        }
    }

    // Mirrors PlatformRecognizer for Downloader-relevant web platforms. These
    // pages are not article candidates, even when captions/comments push body
    // text over the reader threshold.
    function recognizedPlatformPage() {
        var host = (location.hostname || "").toLowerCase();
        var segments = location.pathname.split("/").filter(function (s) { return s.length > 0; });
        if (hostMatches(host, ["youtube.com", "youtube-nocookie.com"]) && youtubeVideoID()) { return "youtube"; }
        if (host === "youtu.be" && segments[0]) { return "youtube"; }
        if (hostMatches(host, ["x.com", "twitter.com"])) { return "x"; }
        if (host === "bsky.app" && segments.indexOf("post") >= 0) { return "bluesky"; }
        if (hostMatches(host, ["reddit.com"]) || host === "redd.it") { return "reddit"; }
        if (hostMatches(host, ["tiktok.com"])) { return "tiktok"; }
        if (hostMatches(host, ["instagram.com", "instagr.am"])) { return "instagram"; }
        if (hostMatches(host, ["facebook.com", "fb.com"]) || host === "fb.watch") { return "facebook"; }
        if (hostMatches(host, ["spotify.com"]) && ["track", "album", "artist", "episode", "show"].indexOf(segments[0]) >= 0) {
            return "spotify";
        }
        if (host === "music.apple.com") { return "appleMusic"; }
        if (host === "podcasts.apple.com") { return "applePodcasts"; }
        return null;
    }

    function hostMatches(host, roots) {
        for (var i = 0; i < roots.length; i++) {
            if (host === roots[i] || host.slice(-("." + roots[i]).length) === "." + roots[i]) { return true; }
        }
        return false;
    }

    function youtubeVideoID() {
        var params = new URLSearchParams(location.search || "");
        if (params.get("v")) { return params.get("v"); }
        var segments = location.pathname.split("/").filter(function (s) { return s.length > 0; });
        if (["shorts", "embed", "live"].indexOf(segments[0]) >= 0 && segments[1]) { return segments[1]; }
        return null;
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
