// Luna Safari annoyance suppression.
//
// Runs at document_start in every frame. Known consent UI is hidden by the
// companion CSS before first paint, then this script chooses an explicit reject /
// necessary-only action when available. A conservative semantic fallback removes
// unsolicited newsletter, app-install, notification, survey, ad-interstitial, and
// ad-block nags only when they are actually overlays. It never targets ordinary ad
// slots, sponsored cards, or inline publisher promotions.

(function () {
    "use strict";

    if (window.__lunaAnnoyanceSuppressionRan) { return; }
    window.__lunaAnnoyanceSuppressionRan = true;

    var HIDDEN_CLASS = "luna-annoyance-hidden";
    var lastInteraction = -Infinity;
    var stats = { consentChoices: 0, consentHidden: 0, popoversHidden: 0 };
    var retryingConsentRoots = new WeakSet();

    // Stable public hooks / markup from the largest CMPs. Text matching below is
    // still required as a fallback because publishers can customize templates.
    var CONSENT_ROOT_SELECTOR = [
        "#onetrust-banner-sdk", "#onetrust-consent-sdk", "#CybotCookiebotDialog",
        "#didomi-host", "#didomi-popup", "#qc-cmp2-container", ".qc-cmp2-container",
        '[id^="sp_message_container_"]', "#trustarc-banner-container", ".truste_box_overlay",
        ".osano-cm-window", ".osano-cm-dialog", ".cky-consent-container",
        "#cookie-law-info-bar", ".cli-modal", "#cmplz-cookiebanner-container",
        ".cmplz-cookiebanner", "#consent_blackbar", "#klaro", ".klaro .cookie-notice",
        '[id*="cookie-banner" i]', '[class*="cookie-banner" i]',
        '[id*="cookie-consent" i]', '[class*="cookie-consent" i]',
        '[id*="consent-banner" i]', '[class*="consent-banner" i]'
    ].join(",");

    var REJECT_SELECTOR = [
        "#onetrust-reject-all-handler",
        "#CybotCookiebotDialogBodyButtonDecline",
        "#didomi-notice-disagree-button",
        ".didomi-continue-without-agreeing",
        '[data-testid="uc-deny-all-button"]',
        '[data-testid="reject-all"]',
        '[data-testid="consent-reject-all"]',
        '[data-cky-tag="reject-button"]',
        ".cky-btn-reject",
        ".osano-cm-denyAll",
        "#cmplz-deny",
        ".cmplz-deny",
        '[data-role="reject-all"]',
        '[data-action="reject-all"]'
    ].join(",");

    // Exact normalized labels only. Deliberately excludes vague actions such as
    // "continue", "save", and "close", and never includes an accept action.
    var REJECT_LABELS = new Set([
        "reject all", "reject optional cookies", "reject non-essential cookies",
        "reject nonessential cookies", "deny all", "decline all", "decline cookies",
        "only necessary", "necessary only", "essential only", "use necessary cookies only",
        "continue without accepting", "continue without agreeing",
        "tout refuser", "refuser tout", "uniquement les cookies nécessaires",
        "alle ablehnen", "nur notwendige cookies", "nur erforderliche cookies",
        "rechazar todo", "solo necesarias", "solo cookies necesarias",
        "rifiuta tutto", "solo cookie necessari", "recusar tudo",
        "apenas cookies necessários", "alles weigeren", "alleen noodzakelijke cookies"
    ]);

    var ANNOYANCE_TEXT = [
        /subscribe to (?:our|the) newsletter/,
        /sign up for (?:our|the) newsletter/,
        /get (?:our|the) newsletter/,
        /join (?:our|the) mailing list/,
        /never miss (?:a|another) story/,
        // Broader newsletter / email-capture marketing copy. These stay safe because a
        // popover must ALSO be an overlay, not a protected login/checkout dialog, and
        // not appear right after the user tapped something (see `processPopover`).
        /free newsletter/,
        /in your inbox/,
        /straight to your inbox/,
        /sign up (?:for free|today|now)/,
        /sign up to (?:get|receive)/,
        /enter your email/,
        /your email address/,
        /create (?:a )?free account/,
        /register for free/,
        /get (?:unlimited|full|instant) access/,
        /enable (?:browser |push )?notifications/,
        /turn on (?:browser |push )?notifications/,
        /allow notifications to/,
        /open (?:this|the story|the article|this page) in (?:our|the) app/,
        /continue (?:reading )?in (?:our|the) app/,
        /download (?:our|the) app/,
        /take (?:our|a) (?:quick )?survey/,
        /we'd love your feedback/,
        /disable (?:your )?ad ?block(?:er)?/,
        /turn off (?:your )?ad ?block(?:er)?/,
        /please whitelist (?:us|this site)/,
        /continue to (?:the )?(?:site|article|content)/,
        /close (?:this )?ad(?:vertisement)?/,
        /skip (?:this )?ad(?:vertisement)?/
    ];

    function normalizeLabel(value) {
        return (value || "")
            .toLowerCase()
            .replace(/[\u2018\u2019]/g, "'")
            .replace(/[^\p{L}\p{N}]+/gu, " ")
            .trim()
            .replace(/\s+/g, " ");
    }

    function buttonLabel(button) {
        if (!button) { return ""; }
        return normalizeLabel(
            button.getAttribute("aria-label") || button.value || button.textContent || "");
    }

    function isActionable(button) {
        return !!button && !button.disabled && button.getAttribute("aria-disabled") !== "true";
    }

    function exactRejectButton(root) {
        if (!root || !root.querySelectorAll) { return null; }
        var known = root.matches && root.matches(REJECT_SELECTOR) ? root : root.querySelector(REJECT_SELECTOR);
        if (isActionable(known)) { return known; }

        var buttons = root.querySelectorAll(
            'button, input[type="button"], input[type="submit"], [role="button"], a[href="#"]');
        for (var i = 0; i < buttons.length; i++) {
            if (isActionable(buttons[i]) && REJECT_LABELS.has(buttonLabel(buttons[i]))) {
                return buttons[i];
            }
        }
        return null;
    }

    // An annoyance is something ON TOP OF the page, never the page itself. This is the
    // one hard invariant of the whole suppressor, enforced at the single sink (`hide`)
    // rather than at each caller, because every identity signal we use is a substring
    // match and publishers routinely put transient MODAL/OVERLAY STATE classes on the
    // document itself: NYT's consent vendor adds `fides-overlay-modal-link-shown` to
    // <body>, Bootstrap adds `modal-open`. Such a class makes <body> match the
    // `[class*="overlay" i]` / `[class*="modal" i]` overlay probes, and a publisher
    // page always carries cookie wording plus a reject button somewhere inside it — so
    // without this guard the whole document reads as a consent root and gets
    // `display:none`, blanking the page after first paint.
    //
    // The same reasoning covers a WRAPPER of the page: nothing that contains the
    // document's main content is an annoyance, whatever it is named.
    function holdsPageContent(element) {
        if (element === document.body || element === document.documentElement) { return true; }
        if (!element || !element.querySelector) { return false; }
        return !!element.querySelector('main, article, [role="main"]');
    }

    function hide(element, kind) {
        if (!element || !element.classList || element.classList.contains(HIDDEN_CLASS)) { return false; }
        if (holdsPageContent(element)) { return false; }
        element.classList.add(HIDDEN_CLASS);
        element.setAttribute("data-luna-suppressed", kind);
        return true;
    }

    function clickReject(root) {
        var button = exactRejectButton(root);
        if (!button) { return false; }
        try {
            button.click();
            stats.consentChoices++;
            return true;
        } catch (e) {
            return false;
        }
    }

    function retryConsentChoice(root) {
        if (!root || retryingConsentRoots.has(root)) { return; }
        retryingConsentRoots.add(root);
        // SSR banners can be parsed before their framework hydrates click handlers.
        // Keep them hidden, but retry the privacy-preserving action briefly.
        [250, 750, 1500, 3000].forEach(function (delay) {
            setTimeout(function () {
                if (!root.isConnected || !exactRejectButton(root)) { return; }
                clickReject(root);
            }, delay);
        });
    }

    function semanticConsentRoot(element) {
        if (!element || element.nodeType !== 1) { return null; }
        var known = element.matches(CONSENT_ROOT_SELECTOR)
            ? element
            : element.querySelector(CONSENT_ROOT_SELECTOR);
        if (known && !holdsPageContent(known)) { return known; }

        var overlaySelector = [
            '[role="dialog"]', '[role="alertdialog"]', '[aria-modal="true"]', "dialog",
            '[class*="modal" i]', '[class*="popup" i]', '[class*="overlay" i]'
        ].join(",");
        var candidates = [];
        if (element.matches(overlaySelector)) { candidates.push(element); }
        var closest = element.closest && element.closest(overlaySelector);
        if (closest && candidates.indexOf(closest) < 0) { candidates.push(closest); }
        var descendants = element.querySelectorAll(overlaySelector);
        for (var i = 0; i < descendants.length; i++) { candidates.push(descendants[i]); }

        for (var j = 0; j < candidates.length; j++) {
            var candidate = candidates[j];
            // Skip the document / a content wrapper up front: it would otherwise
            // "win" as the consent root (its text mentions cookies and some reject
            // button lives inside it), and `processConsent` returning true also
            // suppresses the popover scan of everything below it — so the REAL
            // banner further down would never be considered.
            if (holdsPageContent(candidate)) { continue; }
            var identity = normalizeLabel((candidate.id || "") + " " + (candidate.className || ""));
            var text = normalizeLabel((candidate.textContent || "").slice(0, 5000));
            var mentionsConsent = /(?:cookie|consent|privacy preference)/.test(identity + " " + text);
            if (mentionsConsent && exactRejectButton(candidate)) { return candidate; }
        }
        return null;
    }

    function processConsent(element) {
        var root = semanticConsentRoot(element);
        if (!root) { return false; }
        clickReject(root);
        retryConsentChoice(root);
        if (hide(root, "consent")) { stats.consentHidden++; }
        unlockPage();
        return true;
    }

    function hasAnnoyanceLanguage(element) {
        var text = normalizeLabel((element.textContent || "").slice(0, 6000));
        for (var i = 0; i < ANNOYANCE_TEXT.length; i++) {
            if (ANNOYANCE_TEXT[i].test(text)) { return true; }
        }
        return false;
    }

    // A newsletter / email-capture overlay carries an email field but no password or
    // one-time-code field. The caller has already excluded protected dialogs (login,
    // checkout, verification), so an email input remaining here is a marketing capture
    // whatever its copy — this catches email/newsletter modals that use no recognizable
    // annoyance phrasing (or none in a language we match) at all.
    function isEmailCaptureOverlay(element) {
        if (!element.querySelector) { return false; }
        var hasEmail = element.querySelector(
            'input[type="email"], input[autocomplete="email"], input[name*="email" i]');
        if (!hasEmail) { return false; }
        return !element.querySelector('input[type="password"], input[autocomplete="one-time-code"]');
    }

    function isProtectedDialog(element) {
        if (element.querySelector('input[type="password"], input[autocomplete="one-time-code"]')) { return true; }
        var identity = normalizeLabel((element.id || "") + " " + (element.className || ""));
        var text = normalizeLabel((element.textContent || "").slice(0, 2500));
        return /(?:checkout|payment|billing|shopping cart|sign in|log in|two factor|verification code)/
            .test(identity + " " + text);
    }

    function isOverlay(element) {
        if (!element || element.nodeType !== 1 || element === document.body || element === document.documentElement) {
            return false;
        }
        var role = element.getAttribute("role") || "";
        if (role === "dialog" || role === "alertdialog" || element.getAttribute("aria-modal") === "true") {
            return true;
        }
        if (element.tagName === "DIALOG" && element.hasAttribute("open")) { return true; }

        var identity = normalizeLabel((element.id || "") + " " + (element.className || ""));
        var namedOverlay = /(?:modal|popup|pop up|overlay|interstitial|lightbox|takeover)/.test(identity);
        var style;
        try { style = getComputedStyle(element); } catch (e) { return namedOverlay; }
        var positioned = style.position === "fixed" || style.position === "sticky";
        if (namedOverlay && positioned) { return true; }
        if (!positioned) { return false; }

        var rect = element.getBoundingClientRect();
        var viewportArea = Math.max(1, window.innerWidth * window.innerHeight);
        return (rect.width * rect.height) / viewportArea >= 0.18;
    }

    function processPopover(element) {
        if (!element || element.nodeType !== 1) { return false; }
        if (Date.now() - lastInteraction < 1500) { return false; }
        if (!isOverlay(element) || isProtectedDialog(element)) { return false; }
        if (!hasAnnoyanceLanguage(element) && !isEmailCaptureOverlay(element)) { return false; }
        if (hide(element, "popover")) {
            stats.popoversHidden++;
            unlockPage();
        }
        return true;
    }

    function unlockPage() {
        [document.documentElement, document.body].forEach(function (element) {
            if (!element) { return; }
            ["overflow", "position", "height", "touch-action"].forEach(function (property) {
                var value = element.style.getPropertyValue(property);
                if (property === "overflow" && /hidden|clip/.test(value)) {
                    element.style.removeProperty(property);
                } else if (property !== "overflow" && value) {
                    element.style.removeProperty(property);
                }
            });
            Array.from(element.classList || []).forEach(function (name) {
                if (/^(?:modal-open|no-scroll|noscroll|scroll-lock|overflow-hidden)$/i.test(name)) {
                    element.classList.remove(name);
                }
            });
        });
    }

    function candidateOverlays(root) {
        var result = [];
        if (!root || root.nodeType !== 1) { return result; }
        result.push(root);
        if (root.querySelectorAll) {
            var nodes = root.querySelectorAll([
                '[role="dialog"]', '[role="alertdialog"]', '[aria-modal="true"]', "dialog[open]",
                '[class*="modal" i]', '[class*="popup" i]', '[class*="overlay" i]',
                '[class*="interstitial" i]', '[class*="lightbox" i]', '[class*="takeover" i]'
            ].join(","));
            for (var i = 0; i < nodes.length; i++) { result.push(nodes[i]); }
        }
        return result;
    }

    function scan(root) {
        if (!root || root.nodeType !== 1) { return; }
        if (processConsent(root)) { return; }
        var candidates = candidateOverlays(root);
        for (var i = 0; i < candidates.length; i++) {
            if (!candidates[i].classList.contains(HIDDEN_CLASS)) { processPopover(candidates[i]); }
        }
        discoverShadowRoots(root);
    }

    var observer = new MutationObserver(function (mutations) {
        for (var i = 0; i < mutations.length; i++) {
            if (mutations[i].type === "childList") {
                for (var j = 0; j < mutations[i].addedNodes.length; j++) {
                    scan(mutations[i].addedNodes[j]);
                }
            } else if (mutations[i].target && mutations[i].target.nodeType === 1) {
                scan(mutations[i].target);
            }
        }
    });

    function observeRoot(root) {
        try {
            observer.observe(root, {
                childList: true, subtree: true, attributes: true,
                attributeFilter: ["class", "style", "hidden", "open", "role", "aria-modal"]
            });
        } catch (e) {}
    }

    function addShadowStyle(root) {
        if (!root || root.querySelector("style[data-luna-annoyances]")) { return; }
        var style = document.createElement("style");
        style.setAttribute("data-luna-annoyances", "");
        style.textContent = "." + HIDDEN_CLASS
            + "{display:none!important;visibility:hidden!important;opacity:0!important;pointer-events:none!important}";
        root.appendChild(style);
    }

    function discoverShadowRoots(root) {
        if (!root || root.nodeType !== 1) { return; }
        var elements = [root];
        if (root.querySelectorAll) { elements = elements.concat(Array.from(root.querySelectorAll("*"))); }
        for (var i = 0; i < elements.length; i++) {
            if (elements[i].shadowRoot) {
                addShadowStyle(elements[i].shadowRoot);
                observeRoot(elements[i].shadowRoot);
                scan(elements[i].shadowRoot.firstElementChild);
            }
        }
    }

    function recordInteraction() { lastInteraction = Date.now(); }
    document.addEventListener("pointerdown", recordInteraction, true);
    document.addEventListener("touchstart", recordInteraction, true);
    document.addEventListener("keydown", recordInteraction, true);

    if (document.documentElement) {
        observeRoot(document.documentElement);
        scan(document.documentElement);
    } else {
        document.addEventListener("readystatechange", function startWhenReady() {
            if (!document.documentElement) { return; }
            document.removeEventListener("readystatechange", startWhenReady);
            observeRoot(document.documentElement);
            scan(document.documentElement);
        });
    }

    document.addEventListener("DOMContentLoaded", function () { scan(document.documentElement); }, { once: true });

    // Bare-WKWebView verification hooks. They are intentionally read-only except
    // for the explicit rescan function used by deterministic fixtures.
    window.__lunaSuppressAnnoyancesNow = function () { scan(document.documentElement); };
    window.__lunaAnnoyanceStats = function () {
        return {
            consentChoices: stats.consentChoices,
            consentHidden: stats.consentHidden,
            popoversHidden: stats.popoversHidden
        };
    };
}());
