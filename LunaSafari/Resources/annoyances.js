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
    // A refusal has LANDED for this root / a two-step flow has been started for it.
    // Every path that can click is idempotent per root, because the MutationObserver
    // rescans a root every time this script touches it (adding the hidden class is
    // itself an attribute mutation) and the retry ladder fires four more times. The
    // action is idempotent for the SITE, but a script that clicks a banner five
    // times is one that cannot report what it did.
    var answeredConsentRoots = new WeakSet();
    var twoStepConsentRoots = new WeakSet();

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
        // `normalizeLabel` strips the apostrophe, so the phrase arrives as "we d".
        /we d love your feedback/,
        /disable (?:your )?ad ?block(?:er)?/,
        /turn off (?:your )?ad ?block(?:er)?/,
        /please whitelist (?:us|this site)/,
        /continue to (?:the )?(?:site|article|content)/,
        /close (?:this )?ad(?:vertisement)?/,
        /skip (?:this )?ad(?:vertisement)?/,
        // Subscription and membership nags — the standing "become a member" ribbon a
        // publisher pins over its own article. Such a ribbon is an overlay by every
        // other measure this layer uses; only its wording went unmatched, so a page
        // could carry one permanently with nothing suppressed. Each pattern is an
        // ASK, never the bare word "subscribe": a nav item reading "Subscribe", a
        // footer link, or an article ABOUT subscriptions must not read as an
        // annoyance. `normalizeLabel` has already removed the punctuation these
        // phrases are usually written with ("$2/week." arrives as "2 week").
        /become a (?:[a-z]+ )?member\b/,
        /become a (?:[a-z]+ )?subscriber\b/,
        /subscribe to (?:continue|read|keep reading|unlock)/,
        /subscribe (?:now )?(?:for|from) (?:just|only|less than|as little as)/,
        /start your (?:free )?(?:trial|subscription|membership)/,
        /support (?:our|independent|trusted|quality) journalism/
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
        // The gate, checked HERE too: the retry ladder and a two-step flow both fire
        // from timers that outlive the decision, so a late "off" answer has to stop
        // them as well as reveal what was already hidden.
        if (gate === GATE_OFF) { return false; }
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
        if (!root || answeredConsentRoots.has(root)) { return false; }
        if (!clickRefusal(exactRejectButton(root))) { return false; }
        answeredConsentRoots.add(root);
        return true;
    }

    // A recognized CMP whose first layer offers no reject: open its settings pane
    // and click its own refuse-all control when that appears. Only the flows in
    // `TWO_STEP_FLOWS` are attempted, and the opener is vetoed like any other
    // click — a publisher who relabelled it "Accept and manage" gets nothing.
    function beginTwoStepRefusal(root) {
        if (!root || !root.querySelector || twoStepConsentRoots.has(root)) { return false; }
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
            twoStepConsentRoots.add(root);
            stats.twoStepFlows++;
            completeTwoStepRefusal(root, scope, flow.refuse, 0);
            return true;
        }
        return false;
    }

    // The second half, retried on the same ladder logic as a hydrating banner:
    // the pane is usually rendered on demand, so the control does not exist at the
    // moment the opener is clicked.
    function completeTwoStepRefusal(root, scope, selector, attempt) {
        var delays = [100, 250, 600, 1200];
        if (scope.querySelector && clickRefusal(scope.querySelector(selector))) {
            answeredConsentRoots.add(root);
            return;
        }
        if (attempt >= delays.length) { return; }
        setTimeout(function () {
            completeTwoStepRefusal(root, scope, selector, attempt + 1);
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

    // Returns the consent root it recognized, or null. Non-null on EVERY branch
    // that found one, including "off": this IS consent UI, so the generic popover
    // pass must not reconsider it — least of all when the user has asked to answer
    // cookie prompts themselves, where re-entering as a "popover" would hide the
    // very dialog we just revealed.
    function processConsent(element) {
        var root = semanticConsentRoot(element);
        if (!root) { return null; }
        if (gate === GATE_OFF) { return root; }
        if (gate === GATE_PENDING) {
            deferConsentRoot(root);
            return root;
        }
        answerConsent(root);
        return root;
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

    // A bar shorter than this is page furniture — a reading-progress rule, a rank
    // of breadcrumbs — rather than something that takes the screen.
    var PINNED_BAR_MIN_HEIGHT = 40;
    // How close to an edge still counts as held against it. Another pinned bar (an
    // ad slot, a toolbar) commonly sits between a nag and the edge, so exact
    // contact is too strict a test.
    var PINNED_BAR_EDGE_FRACTION = 0.1;

    // A full-width bar held against the top or bottom of the viewport. The area
    // gate asks "does this cover enough of the screen", which is the wrong question
    // for a bar: a nag ribbon follows the reader down the page and cannot be
    // dismissed, and its area is small BECAUSE it is a bar. It still has to carry
    // annoyance language before anything hides it, so an ad slot — which carries no
    // copy at all — is unaffected by this branch.
    function isPinnedBar(element, rect, viewportWidth, viewportHeight) {
        if (rect.height < PINNED_BAR_MIN_HEIGHT) { return false; }
        if (rect.width < viewportWidth * 0.95) { return false; }
        // Scrolled out of the viewport: held against nothing.
        if (rect.bottom <= 0 || rect.top >= viewportHeight) { return false; }
        var slack = viewportHeight * PINNED_BAR_EDGE_FRACTION;
        return rect.top <= slack || rect.bottom >= viewportHeight - slack;
    }

    // Site navigation is not an annoyance. A publisher's pinned header and its menu
    // panel carry marketing copy often enough to match the text list, and hiding
    // either takes the page's own controls away with it.
    //
    // Three shapes, because the menu PANEL is usually a nameless div INSIDE the
    // <header> rather than the <header> itself: the element is chrome, it contains
    // chrome, or it sits inside chrome and is itself a cluster of links. The link
    // count is what separates that panel from a nag ribbon a publisher happens to
    // render inside its header — a ribbon asks one thing and links once or twice.
    var SITE_CHROME_SELECTOR = 'nav, header, [role="navigation"], [role="banner"]';
    var MENU_LINK_COUNT = 4;

    function holdsSiteChrome(element) {
        if (element.matches && element.matches(SITE_CHROME_SELECTOR)) { return true; }
        if (element.querySelector && element.querySelector(SITE_CHROME_SELECTOR)) { return true; }
        if (!element.closest || !element.closest(SITE_CHROME_SELECTOR)) { return false; }
        return !!element.querySelectorAll
            && element.querySelectorAll("a[href]").length >= MENU_LINK_COUNT;
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
        var viewportWidth = Math.max(1, window.innerWidth);
        var viewportHeight = Math.max(1, window.innerHeight);
        if ((rect.width * rect.height) / (viewportWidth * viewportHeight) >= 0.18) { return true; }
        return isPinnedBar(element, rect, viewportWidth, viewportHeight);
    }

    function processPopover(element) {
        if (!element || element.nodeType !== 1) { return false; }
        if (Date.now() - lastInteraction < 1500) { return false; }
        if (!isOverlay(element) || isProtectedDialog(element) || holdsSiteChrome(element)) { return false; }
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
        var consentRoot = processConsent(root);
        // A recognized consent root normally ENDS the pass: the consent path is
        // acting on this subtree and a second look could only get in its way. With
        // the cookie gate off, though, nothing is acting on it — and returning here
        // would permanently exempt everything under a page that merely CONTAINS a
        // cookie dialog from the rest of the layer, shadow roots included. So the
        // pass continues and the dialog is excluded by identity instead: it is the
        // one element on the page Luna has been told to leave alone, and some cookie
        // walls do say things like "continue to the site".
        if (consentRoot && gate !== GATE_OFF) { return; }
        var candidates = candidateOverlays(root);
        for (var i = 0; i < candidates.length; i++) {
            var candidate = candidates[i];
            if (consentRoot
                && (candidate === consentRoot || consentRoot.contains(candidate)
                    || candidate.contains(consentRoot))) {
                continue;
            }
            if (!candidate.classList.contains(HIDDEN_CLASS)) { processPopover(candidate); }
        }
        discoverShadowRoots(root);
    }

    // ---- The viewport-edge sweep ------------------------------------------
    //
    // `candidateOverlays` finds an annoyance by NAME — a class or id holding
    // "modal", "popup", "overlay". A pinned nag bar routinely has no such name to
    // find: under CSS modules its class is a content hash ("eL2b8AyM"), which says
    // nothing about what the element is, and no selector can be written for it.
    //
    // What such a bar does have is a POSITION. It is held against an edge of the
    // viewport, on top of the page, which is the whole reason it is worth
    // suppressing. So look where the reader is actually being covered: hit-test a
    // few points along the top and bottom edges and consider whatever is stacked
    // there. The cost is a fixed handful of hit tests rather than a walk of the
    // document, and it depends on no markup convention at all.
    //
    // Everything found still goes through the same ladder as any other candidate —
    // overlay shape, no protected dialog, annoyance language, the page-content
    // guard in `hide`. This only decides what gets LOOKED at.

    // Rows as fractions of viewport height. The two inset from each edge clear a
    // bar that is already pinned there (an ad slot, a toolbar) so a nag stacked
    // above it is still found.
    var EDGE_PROBE_ROWS = [0.005, 0.04, 0.90, 0.95, 0.99];
    var EDGE_PROBE_COLUMNS = [0.2, 0.5, 0.8];
    // A sticky bar moves with the page and appears on scroll without mutating, so
    // the sweep answers to scrolling too. Trailing-throttled: this forces layout.
    var EDGE_SWEEP_INTERVAL = 500;
    var edgeSweepTimer = null;
    var lastEdgeSweep = -Infinity;

    function considerEdgeElement(element) {
        if (!element || element.nodeType !== 1) { return; }
        // The page itself is never a nag, and this is the cheap test — it keeps the
        // subtree queries below off <body>, <html> and every content wrapper in the
        // hit-test stack.
        if (holdsPageContent(element)) { return; }
        if (element.classList && element.classList.contains(HIDDEN_CLASS)) { return; }
        // Consent UI has its own path and its own user switch. The generic popover
        // pass must never reconsider it — least of all with auto-decline off, where
        // hiding the dialog would take away the choice the user asked to make.
        if (semanticConsentRoot(element)) { return; }
        processPopover(element);
    }

    function sweepViewportEdges() {
        lastEdgeSweep = Date.now();
        if (!document.elementsFromPoint) { return; }
        var width = window.innerWidth, height = window.innerHeight;
        if (!width || !height) { return; }
        var seen = [];
        for (var r = 0; r < EDGE_PROBE_ROWS.length; r++) {
            for (var c = 0; c < EDGE_PROBE_COLUMNS.length; c++) {
                var stack;
                try {
                    stack = document.elementsFromPoint(
                        EDGE_PROBE_COLUMNS[c] * width, EDGE_PROBE_ROWS[r] * height);
                } catch (e) { continue; }
                for (var i = 0; i < stack.length; i++) {
                    if (seen.indexOf(stack[i]) < 0) { seen.push(stack[i]); }
                }
            }
        }
        for (var j = 0; j < seen.length; j++) { considerEdgeElement(seen[j]); }
    }

    function scheduleEdgeSweep() {
        if (edgeSweepTimer !== null) { return; }
        var wait = Math.max(0, EDGE_SWEEP_INTERVAL - (Date.now() - lastEdgeSweep));
        edgeSweepTimer = setTimeout(function () {
            edgeSweepTimer = null;
            sweepViewportEdges();
        }, wait);
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
        scheduleEdgeSweep();
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
    // `browser` object at all. This script is the same in all four apps and asks
    // the same question in each; the Downloader's and Price Tracker's native
    // handler simply always answers true, because they expose no control.

    var GATE_PENDING = 0, GATE_ON = 1, GATE_OFF = 2;
    var GATE_TIMEOUT = 1000;
    var gate = GATE_PENDING;
    // Consent roots recognized while the answer was still in flight. Bounded —
    // the rescan `applyGate` runs finds anything this list had to drop.
    var deferredConsentRoots = [];
    // Whether the document-start pass has already run (see `applyGate`).
    var hasScanned = false;

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
        // Only worth a rescan if the answer arrived AFTER the first pass; when there
        // is no `browser` to ask, this resolves before any scanning has happened.
        if (hasScanned && document.documentElement) { scan(document.documentElement); }
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
        hasScanned = true;
        observeRoot(document.documentElement);
        scan(document.documentElement);
    } else {
        document.addEventListener("readystatechange", function startWhenReady() {
            if (!document.documentElement) { return; }
            document.removeEventListener("readystatechange", startWhenReady);
            hasScanned = true;
            observeRoot(document.documentElement);
            scan(document.documentElement);
        });
    }

    document.addEventListener("DOMContentLoaded", function () {
        scan(document.documentElement);
        scheduleEdgeSweep();
    }, { once: true });
    window.addEventListener("load", scheduleEdgeSweep, { once: true });
    // A sticky bar reaches its pinned position by SCROLLING, with no mutation to
    // observe — a nag that only shows up part-way down the article is reached here
    // and nowhere else.
    window.addEventListener("scroll", scheduleEdgeSweep, { passive: true });

    // Bare-WKWebView verification hooks. They are intentionally read-only except
    // for the explicit rescan function used by deterministic fixtures.
    window.__lunaSuppressAnnoyancesNow = function () {
        scan(document.documentElement);
        sweepViewportEdges();
    };
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
