// Luna Safari annoyance suppression.
//
// Runs at document_start in every frame. Known consent UI is hidden by the
// companion CSS before first paint, then this script chooses an explicit reject /
// necessary-only action when available. A conservative semantic fallback removes
// unsolicited newsletter, app-install, notification, survey, ad-interstitial, and
// ad-block nags only when they are actually overlays. It never targets ordinary ad
// slots, sponsored cards, or inline publisher promotions.
//
// The CONSENT half is the one part the user can switch off ("Decline cookies for
// me", Settings → Safari in Luna and Reader). A content script cannot reach the
// native handler, so the answer arrives via a background.js relay — which means it
// arrives LATE, after this script has already run. Consent actions are therefore
// DEFERRED until the gate resolves, and every failure mode (no answer, a slow one,
// no `browser` at all) resolves to ENABLED, the shipped behavior.

(function () {
    "use strict";

    if (window.__lunaAnnoyanceSuppressionRan) { return; }
    window.__lunaAnnoyanceSuppressionRan = true;

    var HIDDEN_CLASS = "luna-annoyance-hidden";
    // Set on <html> to switch OFF the companion stylesheet's pre-paint consent
    // hide (annoyances.css keys every consent selector on its absence).
    var ALLOW_COOKIES_ATTRIBUTE = "data-luna-cookies-allowed";
    var lastInteraction = -Infinity;
    var stats = {
        consentChoices: 0, consentHidden: 0, popoversHidden: 0, twoStepFlows: 0
    };
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

    // Each entry is a specific CMP's own documented refuse control. Nothing here
    // is a shape ("the second button", "the secondary-styled one") — Quantcast's
    // `.qc-cmp2-summary-buttons [mode="secondary"]` is deliberately ABSENT for
    // exactly that reason: publishers configure that slot as either "DISAGREE" or
    // "MORE OPTIONS", and clicking the latter opens a preference centre. Its
    // DISAGREE variant is caught by the label pass below instead, which reads what
    // the button actually says.
    var REJECT_SELECTOR = [
        "#onetrust-reject-all-handler",
        ".ot-pc-refuse-all-handler",
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
        // TrustArc's "Required Cookies Only" control on its own banner.
        "#truste-consent-required",
        // Sourcepoint renders its first layer inside an `sp_message_iframe_*`
        // frame; `all_frames` means this script runs INSIDE that frame, where the
        // wrapper is `.message-container` rather than the parent document's
        // `.sp_message_container`. Both are scoped to the exact title, so neither
        // can match an unrelated button.
        '.sp_message_container button[title="reject all" i]',
        '.message-container button[title="reject all" i]',
        '[data-role="reject-all"]',
        '[data-action="reject-all"]'
    ].join(",");

    // Exact normalized labels only. Deliberately excludes vague actions such as
    // "continue", "save", and "close", and never includes an accept action —
    // exactness IS the safety property here, so nothing below is a substring or a
    // pattern. Ordered by language: English, French, German, Spanish, Italian,
    // Dutch, Portuguese, Polish, Danish/Norwegian, Swedish.
    var REJECT_LABELS = new Set([
        "reject", "reject all", "reject cookies", "reject all cookies",
        "reject optional cookies", "reject non essential cookies",
        "reject nonessential cookies", "deny all", "deny cookies",
        "decline", "decline all", "decline cookies", "decline optional cookies",
        "disagree", "i disagree", "do not agree", "i do not agree", "do not consent",
        "only necessary", "necessary only", "necessary cookies only",
        "only necessary cookies", "essential only", "essential cookies only",
        "only essential cookies", "use necessary cookies only",
        "continue without accepting", "continue without agreeing",
        "tout refuser", "refuser tout", "refuser", "refuser tous les cookies",
        "continuer sans accepter", "uniquement les cookies nécessaires",
        "cookies nécessaires uniquement",
        "alle ablehnen", "alles ablehnen", "ablehnen", "nur notwendige",
        "nur notwendige cookies", "nur erforderliche cookies",
        "nur essenzielle cookies", "weiter ohne einwilligung",
        "rechazar todo", "rechazar todas", "rechazar cookies",
        "rechazar todas las cookies", "denegar todo", "solo necesarias",
        "solo cookies necesarias", "solo las necesarias", "solo esenciales",
        "continuar sin aceptar",
        "rifiuta tutto", "rifiuta tutti", "rifiuta tutti i cookie",
        "solo cookie necessari", "solo i cookie necessari",
        "continua senza accettare",
        "alles weigeren", "weiger alles", "alles afwijzen", "afwijzen",
        "alleen noodzakelijke", "alleen noodzakelijke cookies",
        "alleen essentiële cookies", "doorgaan zonder accepteren",
        "recusar tudo", "rejeitar tudo", "rejeitar todos",
        "rejeitar todos os cookies", "apenas cookies necessários",
        "apenas os necessários", "continuar sem aceitar",
        "odrzuć wszystkie", "odrzuć wszystko", "odrzuć wszystkie pliki cookie",
        "odrzuć", "tylko niezbędne", "tylko niezbędne pliki cookie",
        "nie zgadzam się",
        "afvis alle", "afvis alt", "kun nødvendige", "kun nødvendige cookies",
        "avvis alle", "avvis alt", "bare nødvendige",
        "avvisa alla", "avvisa allt", "neka alla", "endast nödvändiga",
        "endast nödvändiga cookies", "bara nödvändiga"
    ]);

    // The one thing Luna must never click, checked at the single click sink rather
    // than trusted per source: the curated label set above already excludes accept
    // actions, but a CMP selector and a two-step flow both resolve to whatever
    // markup a publisher actually shipped. Word-START boundaries matter — "agree"
    // must not fire on "disagree", and "accept" must fire on "accepting" so the
    // negation clause below is what saves "continue without accepting".
    var ACCEPT_WORDS = new RegExp(
        "\\b(?:accept|agree|allow|opt in|akzept|zustimm|einverstanden|einwillig"
        + "|accepter|accett|acept|aceit|akkoord|godta|acceptera|tillad"
        + "|zgadzam|zaakceptuj|zezwól|zulassen)");
    var REFUSAL_WORDS = new RegExp(
        "\\b(?:without|sans|sin|senza|sem|ohne|zonder|bez|uden|utan|uten|ikke|inte"
        + "|nie|niet|non|not|no|nej|nein|reject|refuse|refuser|decline|deny)\\b");

    function readsAsAccept(label) {
        if (!ACCEPT_WORDS.test(label)) { return false; }
        // "continue without accepting", "nie zgadzam się", "niet akkoord": an
        // accept word inside an explicit refusal is still a refusal.
        return !REFUSAL_WORDS.test(label);
    }

    // Deterministic two-step refusals, for named CMPs ONLY: a first layer with no
    // reject button, plus that CMP's own documented refuse-all control one screen
    // in. Both halves are fixed markup — nothing here searches a preference centre
    // for a plausible-looking button, and the accept veto still applies to each
    // click. `scope` is where the second control appears, which for OneTrust is the
    // document (the panel is a SIBLING of the banner, not a descendant).
    var TWO_STEP_FLOWS = [
        { opener: "#onetrust-pc-btn-handler", refuse: ".ot-pc-refuse-all-handler" }
    ];

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

    // The ONE place a consent control is ever activated. Every source of a
    // button — known selector, exact label, two-step flow — funnels through here,
    // so the accept veto cannot be forgotten by a new caller.
    function clickRefusal(button) {
        if (!isActionable(button) || readsAsAccept(buttonLabel(button))) { return false; }
        try {
            button.click();
            stats.consentChoices++;
            return true;
        } catch (e) {
            return false;
        }
    }

    function clickReject(root) {
        return clickRefusal(exactRejectButton(root));
    }

    // A recognized CMP whose first layer offers no reject: open its settings pane
    // and click its own refuse-all control when that appears. Only the flows in
    // `TWO_STEP_FLOWS` are attempted, and the opener is vetoed like any other
    // click — a publisher who relabelled it "Accept and manage" gets nothing.
    function beginTwoStepRefusal(root) {
        if (!root || !root.querySelector) { return false; }
        var scope = (root.getRootNode && root.getRootNode()) || document;
        for (var i = 0; i < TWO_STEP_FLOWS.length; i++) {
            var flow = TWO_STEP_FLOWS[i];
            var opener = root.querySelector(flow.opener) || (scope.querySelector
                ? scope.querySelector(flow.opener) : null);
            if (!isActionable(opener) || readsAsAccept(buttonLabel(opener))) { continue; }
            try {
                opener.click();
            } catch (e) {
                continue;
            }
            stats.twoStepFlows++;
            completeTwoStepRefusal(scope, flow.refuse, 0);
            return true;
        }
        return false;
    }

    // The second half, retried on the same ladder logic as a hydrating banner:
    // the pane is usually rendered on demand, so the control does not exist at the
    // moment the opener is clicked.
    function completeTwoStepRefusal(scope, selector, attempt) {
        var delays = [100, 250, 600, 1200];
        if (scope.querySelector && clickRefusal(scope.querySelector(selector))) { return; }
        if (attempt >= delays.length) { return; }
        setTimeout(function () {
            completeTwoStepRefusal(scope, selector, attempt + 1);
        }, delays[attempt]);
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
        // TRUE on every branch: this IS consent UI, so the generic popover pass
        // must not reconsider it — least of all when the user has asked to answer
        // cookie prompts themselves, where re-entering as a "popover" would hide
        // the very dialog we just revealed.
        if (gate === GATE_OFF) { return true; }
        if (gate === GATE_PENDING) {
            deferConsentRoot(root);
            return true;
        }
        answerConsent(root);
        return true;
    }

    // Choose the privacy-preserving action, then get the notice out of the way.
    // Only ever reached with the gate resolved ON.
    function answerConsent(root) {
        if (!clickReject(root)) { beginTwoStepRefusal(root); }
        retryConsentChoice(root);
        if (hide(root, "consent")) { stats.consentHidden++; }
        unlockPage();
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

    // ---- The cookie auto-decline gate -------------------------------------
    //
    // "Decline cookies for me" (Settings → Safari, Luna and Reader only) is the
    // one switchable part of this script. A content script cannot call
    // `sendNativeMessage`, so the answer comes back through background.js — after
    // this script has already run at document_start. Rather than act and undo,
    // consent actions WAIT: while the answer is in flight a recognized banner is
    // remembered and left alone, and the companion stylesheet keeps it hidden, so
    // the user sees no flash whichever way the answer goes.
    //
    // Every failure resolves to ENABLED (the shipped behavior, and what a user who
    // never opened Settings gets): no answer inside a second, a rejected relay, no
    // `browser` object at all. The Downloader and Price Tracker never even ask
    // themselves the question differently — their native handler always answers
    // true, because they expose no control.

    var GATE_PENDING = 0, GATE_ON = 1, GATE_OFF = 2;
    var GATE_TIMEOUT = 1000;
    var gate = GATE_PENDING;
    // Consent roots recognized while the answer was still in flight. Bounded —
    // the rescan `applyGate` runs finds anything this list had to drop.
    var deferredConsentRoots = [];

    function deferConsentRoot(root) {
        if (deferredConsentRoots.length >= 8) { return; }
        if (deferredConsentRoots.indexOf(root) >= 0) { return; }
        deferredConsentRoots.push(root);
    }

    // Flips the companion stylesheet's pre-paint consent hide on or off. One
    // attribute on <html>, which every consent selector in annoyances.css is
    // keyed on — deterministic in a way a competing "revert" stylesheet is not.
    function setCookiesAllowed(allowed) {
        if (!document.documentElement) {
            document.addEventListener("readystatechange", function once() {
                if (!document.documentElement) { return; }
                document.removeEventListener("readystatechange", once);
                setCookiesAllowed(gate === GATE_OFF);
            });
            return;
        }
        if (allowed) {
            document.documentElement.setAttribute(ALLOW_COOKIES_ATTRIBUTE, "");
        } else {
            document.documentElement.removeAttribute(ALLOW_COOKIES_ATTRIBUTE);
        }
    }

    function revealConsentUI() {
        setCookiesAllowed(true);
        // And anything this script had already hidden itself, so the late `off`
        // answer of a slow relay still leaves the page answerable.
        var hidden = document.querySelectorAll
            ? document.querySelectorAll('[data-luna-suppressed="consent"]') : [];
        for (var i = 0; i < hidden.length; i++) {
            hidden[i].classList.remove(HIDDEN_CLASS);
            hidden[i].removeAttribute("data-luna-suppressed");
        }
    }

    function applyGate(enabled) {
        gate = enabled ? GATE_ON : GATE_OFF;
        if (!enabled) {
            deferredConsentRoots = [];
            revealConsentUI();
            return;
        }
        setCookiesAllowed(false);
        var roots = deferredConsentRoots;
        deferredConsentRoots = [];
        for (var i = 0; i < roots.length; i++) {
            if (roots[i].isConnected) { answerConsent(roots[i]); }
        }
        if (document.documentElement) { scan(document.documentElement); }
    }

    function resolveGate() {
        var override = window.__lunaCookieAutoDecline;
        if (typeof browser === "undefined" || !browser.runtime || !browser.runtime.sendMessage) {
            applyGate(typeof override === "boolean" ? override : true);
            return;
        }
        var settled = false;
        var timer = null;
        function settle(enabled) {
            if (settled) { return; }
            settled = true;
            if (timer !== null) { clearTimeout(timer); }
            applyGate(enabled);
        }
        timer = setTimeout(function () { settle(true); }, GATE_TIMEOUT);
        try {
            var answer = browser.runtime.sendMessage({ type: "annoyanceSettings" });
            if (!answer || !answer.then) {
                settle(true);
                return;
            }
            answer.then(function (resp) {
                settle(!(resp && resp.cookieAutoDecline === false));
            }).catch(function () { settle(true); });
        } catch (e) {
            settle(true);
        }
    }

    function recordInteraction() { lastInteraction = Date.now(); }
    document.addEventListener("pointerdown", recordInteraction, true);
    document.addEventListener("touchstart", recordInteraction, true);
    document.addEventListener("keydown", recordInteraction, true);

    // Kicked off BEFORE the first scan: with no `browser` to ask (the tests' bare
    // WKWebView) it resolves synchronously, so nothing is ever deferred there.
    resolveGate();

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
    // The gate, without a background page to relay it: set
    // `window.__lunaCookieAutoDecline = false` BEFORE this script is evaluated to
    // start off, or call this to flip it afterwards (which reveals what was
    // already hidden, exactly as a slow relay answering `false` does).
    window.__lunaSetCookieAutoDecline = function (enabled) { applyGate(!!enabled); };
    window.__lunaAnnoyanceStats = function () {
        return {
            consentChoices: stats.consentChoices,
            consentHidden: stats.consentHidden,
            popoversHidden: stats.popoversHidden,
            twoStepFlows: stats.twoStepFlows,
            cookieAutoDecline: gate !== GATE_OFF
        };
    };
}());
