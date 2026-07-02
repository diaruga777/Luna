// Luna Safari content script. Injects a "Read in Luna" button on article pages
// (per the app's visibility setting); tapping it deep-links the page into the
// Luna app, which opens the right viewer — including the in-app archive.today
// flow for paywalled articles. The extension does NO archive.today handling.

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

    browser.runtime.sendMessage({ type: "buttonMode" }).then(function (resp) {
        var mode = (resp && resp.mode) || "all";
        if (mode === "never") { return; }
        if (!looksLikeArticle()) { return; }
        if (mode === "onlyLocked" && !looksPaywalled()) { return; }
        injectReadButton();
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
        function clean() {
            try {
                REMOVE.forEach(function (sel) {
                    document.querySelectorAll(sel).forEach(function (el) { el.remove(); });
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

    function injectReadButton() {
        if (document.getElementById("queue-read-button")) { return; }
        // A <div role="button"> (not a <button>) so the host page's `button {…}`
        // CSS can't clamp its height and cut off the pill. Explicit resets +
        // inline-flex centering + a fully-rounded radius guarantee the pill shape.
        var btn = document.createElement("div");
        btn.id = "queue-read-button";
        btn.setAttribute("role", "button");
        btn.appendChild(document.createTextNode("📖  Read in Luna"));
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
                // A tap is a user gesture, so Safari allows the custom-scheme launch.
                window.location.href = "lunareader://read?url=" + encodeURIComponent(location.href);
            };
            // Hand the app the already-unlocked page HTML so it renders that content
            // instead of re-fetching (which could re-lock outside Safari). Skip when
            // the page is too large for native messaging; the app then fetches the URL.
            var html = "";
            try { html = document.documentElement ? document.documentElement.outerHTML : ""; } catch (e) {}
            if (html && html.length <= 1500000) {
                browser.runtime.sendMessage({ type: "saveContent", url: location.href, html: html })
                    .then(open).catch(open);
            } else {
                open();
            }
        });
        (document.body || document.documentElement).appendChild(btn);
    }

    function applyStyle(el, style) {
        for (var key in style) {
            if (Object.prototype.hasOwnProperty.call(style, key)) {
                el.style[key] = style[key];
            }
        }
    }
})();
