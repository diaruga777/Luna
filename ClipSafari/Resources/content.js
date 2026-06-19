// Queue Safari content script. Injects a "Read in Queue" button on article pages
// (per the app's visibility setting); tapping it deep-links the page into the
// Queue app, which opens the right viewer — including the in-app archive.today
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

    // A page worth a "Read in Queue" button: an article, not a homepage/search.
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
        var btn = document.createElement("button");
        btn.id = "queue-read-button";
        btn.appendChild(document.createTextNode("📖  Read in Queue"));
        applyStyle(btn, {
            position: "fixed", right: "16px",
            bottom: "calc(20px + env(safe-area-inset-bottom))",
            zIndex: "2147483647", background: QUEUE_INDIGO, color: "#ffffff",
            font: "600 16px -apple-system, system-ui, sans-serif",
            border: "none", borderRadius: "23px", padding: "13px 20px",
            boxShadow: "0 6px 20px rgba(0,0,0,0.30)", cursor: "pointer",
            webkitTapHighlightColor: "transparent", touchAction: "manipulation"
        });
        btn.addEventListener("click", function () {
            btn.textContent = "Opening Queue…";
            btn.disabled = true;
            btn.style.opacity = "0.7";
            // A tap is a user gesture, so Safari allows the custom-scheme launch.
            window.location.href = "clickreader://read?url=" + encodeURIComponent(location.href);
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
