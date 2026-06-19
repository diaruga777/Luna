// Queue Safari content script. Two roles, chosen by host:
//
//  1. On a hard-paywall article (WSJ/FT/…): inject a Queue-styled "Read in Queue"
//     button. Tapping it asks the background script to redirect THIS tab to the
//     article's archive.today snapshot (background remembers it redirected the tab).
//
//  2. On an archive.today page reached BY THAT redirect (and ONLY then — we never
//     auto-save an arbitrary archive.is visit): once the real article is loaded
//     (past the Cloudflare CAPTCHA), strip the page down to compact HTML and hand
//     it to the native app, then show a "Saved to Queue" banner.
//
// Content scripts can't message the native app directly, so everything is relayed
// through background.js (browser.runtime.sendMessage → sendNativeMessage).

(function () {
    "use strict";

    // The background script injects this with scripting.executeScript, which can
    // fire more than once per document — run our setup only the first time.
    if (window.__queueContentScriptRan) { return; }
    window.__queueContentScriptRan = true;

    var QUEUE_INDIGO = "#5856D6";

    var PAYWALL_HOSTS = [
        "wsj.com", "ft.com", "nytimes.com", "economist.com", "bloomberg.com",
        "washingtonpost.com", "newyorker.com", "theatlantic.com", "wired.com",
        "barrons.com", "businessinsider.com", "theinformation.com", "hbr.org",
        "foreignpolicy.com", "foreignaffairs.com", "thetimes.co.uk", "telegraph.co.uk",
        "nikkei.com", "seekingalpha.com", "latimes.com", "bostonglobe.com"
    ];
    var ARCHIVE_HOSTS = [
        "archive.is", "archive.ph", "archive.md", "archive.today",
        "archive.li", "archive.vn", "archive.fo"
    ];

    function hostMatches(list) {
        var h = location.hostname.replace(/^www\./, "").toLowerCase();
        return list.some(function (d) { return h === d || h.endsWith("." + d); });
    }

    if (hostMatches(ARCHIVE_HOSTS)) {
        initArchiveHarvest();
    } else if (hostMatches(PAYWALL_HOSTS)) {
        injectReadButton();
    }

    // MARK: paywall host — the button

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
            btn.textContent = "Opening archive…";
            btn.disabled = true;
            btn.style.opacity = "0.7";
            browser.runtime.sendMessage({ type: "queueRedirect", url: location.href });
        });
        appendWhenReady(btn);
    }

    // MARK: archive host — harvest (only for our redirects)

    function initArchiveHarvest() {
        browser.runtime.sendMessage({ type: "isQueueRedirect" }).then(function (resp) {
            if (!resp || !resp.redirect) { return; }   // not one of our redirects → never auto-save
            waitForArticleThenHarvest(resp.originalURL);
        }).catch(function () {});
    }

    function isChallengePage() {
        if (document.querySelector('form[action*="chk_captcha"], #challenge-running, #cf-challenge-running')) {
            return true;
        }
        var title = (document.title || "").toLowerCase();
        if (title.indexOf("just a moment") >= 0 || title.indexOf("attention required") >= 0) {
            return true;
        }
        var body = document.body ? document.body.innerText : "";
        return body.indexOf("Why do I have to complete a CAPTCHA") >= 0
            || body.indexOf("Checking your browser") >= 0;
    }

    function waitForArticleThenHarvest(originalURL) {
        var tries = 0;
        var maxTries = 150;   // ~2.5 min at 1s — generous, for slow CAPTCHA solving
        var timer = setInterval(function () {
            tries += 1;
            if (tries > maxTries) { clearInterval(timer); return; }
            if (isChallengePage()) { return; }                       // user still solving
            var text = document.body ? document.body.innerText : "";
            if (text.length < 1500) { return; }                      // article not loaded yet
            clearInterval(timer);
            harvest(originalURL);
        }, 1000);
    }

    // Strips the page to compact HTML: drops scripts/styles/svg/iframes and the
    // inline style/class attributes archive.today puts on every element (the bulk
    // of its ~1MB weight), keeping the tags/text/links the native extractor needs.
    function reducedHTML() {
        var clone = document.documentElement.cloneNode(true);
        var drop = clone.querySelectorAll("script,style,svg,noscript,iframe,link,template,form,canvas");
        for (var i = 0; i < drop.length; i++) { drop[i].remove(); }
        var all = clone.querySelectorAll("*");
        for (var j = 0; j < all.length; j++) {
            all[j].removeAttribute("style");
            all[j].removeAttribute("class");
            all[j].removeAttribute("onclick");
            all[j].removeAttribute("srcset");
        }
        return clone.outerHTML;
    }

    function harvest(originalURL) {
        var MAX = 950000;   // safely under the ~1MB native-message limit
        var html = reducedHTML();
        var text = null;
        if (!html || html.length > MAX) {
            html = null;
            text = (document.body ? document.body.innerText : "").slice(0, MAX);
        }
        browser.runtime.sendMessage({
            type: "archiveContent",
            url: originalURL || location.href,
            title: document.title || "",
            html: html,
            text: text
        });
        showSavedBanner();
    }

    function showSavedBanner() {
        if (document.getElementById("queue-saved-banner")) { return; }
        var existing = document.getElementById("queue-read-button");
        if (existing) { existing.remove(); }

        var bar = document.createElement("div");
        bar.id = "queue-saved-banner";
        applyStyle(bar, {
            position: "fixed", left: "0", right: "0", top: "0", zIndex: "2147483647",
            background: QUEUE_INDIGO, color: "#ffffff",
            font: "600 15px -apple-system, system-ui, sans-serif",
            padding: "calc(10px + env(safe-area-inset-top)) 16px 11px",
            display: "flex", alignItems: "center", justifyContent: "space-between",
            boxShadow: "0 2px 14px rgba(0,0,0,0.28)",
            transform: "translateY(-100%)", transition: "transform 0.32s ease"
        });
        var label = document.createElement("span");
        label.appendChild(document.createTextNode("✓  Saved to Queue"));
        var open = document.createElement("button");
        open.appendChild(document.createTextNode("Open Queue"));
        applyStyle(open, {
            background: "rgba(255,255,255,0.22)", color: "#ffffff", border: "none",
            borderRadius: "16px", padding: "8px 15px",
            font: "600 15px -apple-system, system-ui, sans-serif",
            cursor: "pointer", webkitTapHighlightColor: "transparent"
        });
        // A tap is a user gesture, so Safari allows the custom-scheme launch (an app
        // can't be auto-launched without one).
        open.addEventListener("click", function () { window.location.href = "clickreader://saved"; });
        bar.appendChild(label);
        bar.appendChild(open);
        appendWhenReady(bar);
        requestAnimationFrame(function () { bar.style.transform = "translateY(0)"; });
    }

    // MARK: helpers

    function applyStyle(el, style) {
        for (var key in style) {
            if (Object.prototype.hasOwnProperty.call(style, key)) {
                el.style[key] = style[key];
            }
        }
    }

    function appendWhenReady(node) {
        var parent = document.body || document.documentElement;
        if (parent) { parent.appendChild(node); return; }
        document.addEventListener("DOMContentLoaded", function () {
            (document.body || document.documentElement).appendChild(node);
        });
    }
})();
