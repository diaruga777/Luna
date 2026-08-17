//
//  SafariAnnoyanceSuppressionTests.swift
//  LunaTests
//

@testable import Luna
import XCTest

/// Exercises the document-start annoyance script in the shared bare-`WKWebView`
/// harness (`SafariJSTestHarness`). These fixtures focus on the safety boundary:
/// consent is rejected, true popovers are hidden, and inline ads / user-critical
/// dialogs are left alone.
@MainActor
final class SafariAnnoyanceSuppressionTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    /// The companion stylesheet, inlined into a fixture that needs the REAL
    /// pre-paint hide rather than only the class the script adds — the cookie
    /// gate's whole off path is "the declarative rule stops matching".
    private static let annoyanceCSS = SafariJSTestHarness.source(
        "LunaSafari/Resources/annoyances.css")

    /// `cookieAutoDecline` pre-sets the gate the way a background-page relay
    /// would answer, BEFORE the script runs — `annoyances.js` reads
    /// `window.__lunaCookieAutoDecline` only when there is no `browser` to ask,
    /// which is exactly this harness. `nil` leaves the shipped default (on).
    private func evaluate(
        _ expression: String, html: String, cookieAutoDecline: Bool? = nil
    ) -> String? {
        var scripts: [String] = []
        if let cookieAutoDecline {
            scripts.append("window.__lunaCookieAutoDecline = \(cookieAutoDecline);")
        }
        scripts.append(SafariJSTestHarness.annoyances)
        js.load(html: html, urlString: "https://example.com/story", scripts: scripts)
        return js.string(expression)
    }

    /// A OneTrust banner over a real article, with the production stylesheet in
    /// the page so `display` reflects the gate and not just the hidden class.
    private static let styledOneTrustPage = """
    <html><head><style>\(annoyanceCSS)</style></head><body>
    <div id="onetrust-banner-sdk">
      <p>We use cookies to personalize content.</p>
      <button id="onetrust-accept-btn-handler">Accept all</button>
      <button id="onetrust-reject-all-handler"
              onclick="document.body.dataset.choice='rejected'">Reject all</button>
    </div>
    <main><article><p>The story survives either answer.</p></article></main>
    </body></html>
    """

    /// Everything the gate decides, read off one page: is the banner painted, did
    /// Luna touch it, did the site hear an answer, and what does the script think
    /// the setting is.
    private static let gateReport = """
    (function () {
      var banner = document.querySelector('#onetrust-banner-sdk');
      var stats = window.__lunaAnnoyanceStats();
      return [getComputedStyle(banner).display,
              banner.dataset.lunaSuppressed || 'untouched',
              document.body.dataset.choice || 'none',
              String(stats.consentChoices),
              String(stats.cookieAutoDecline),
              String(document.documentElement.hasAttribute('data-luna-cookies-allowed')),
              document.querySelector('article') ? 'content' : 'gone'].join('|');
    }())
    """

    func testOneTrustRejectAllIsChosenAndBannerIsHidden() {
        let html = """
        <html><body>
        <div id="onetrust-banner-sdk">
          <p>We use cookies to personalize content.</p>
          <button id="onetrust-accept-btn-handler">Accept all</button>
          <button id="onetrust-reject-all-handler"
                  onclick="document.body.dataset.choice='rejected'">Reject all</button>
        </div>
        </body></html>
        """
        let result = evaluate(
            "document.body.dataset.choice + '|' + document.querySelector('#onetrust-banner-sdk').dataset.lunaSuppressed",
            html: html)
        XCTAssertEqual(result, "rejected|consent")
    }

    func testGenericConsentChoosesNecessaryOnly() {
        let html = """
        <html><body>
        <div id="privacy-choice" role="dialog" aria-modal="true">
          <p>Choose how this site may use cookies.</p>
          <button onclick="document.body.dataset.choice='all'">Accept all</button>
          <button onclick="document.body.dataset.choice='necessary'">Only necessary</button>
        </div>
        </body></html>
        """
        let result = evaluate(
            "document.body.dataset.choice + '|' + document.querySelector('#privacy-choice').dataset.lunaSuppressed",
            html: html)
        XCTAssertEqual(result, "necessary|consent")
    }

    func testNewsletterOverlayIsHidden() {
        let html = """
        <html><body>
        <article><p>Publisher content remains readable.</p></article>
        <div id="newsletter" class="newsletter-modal" role="dialog"
             style="position:fixed;inset:0">
          <p>Subscribe to our newsletter</p><button>Not now</button>
        </div>
        </body></html>
        """
        XCTAssertEqual(
            evaluate("document.querySelector('#newsletter').dataset.lunaSuppressed || 'visible'", html: html),
            "popover")
    }

    func testInlineAdvertisingIsPreserved() {
        let html = """
        <html><body>
        <article>
          <p>Publisher content.</p>
          <aside id="sponsor" class="advertisement">Advertisement from a sponsor</aside>
        </article>
        </body></html>
        """
        XCTAssertEqual(
            evaluate("document.querySelector('#sponsor').dataset.lunaSuppressed || 'visible'", html: html),
            "visible")
    }

    func testLoginDialogIsPreservedEvenIfItMentionsNewsletter() {
        let html = """
        <html><body>
        <div id="login" class="account-modal" role="dialog" style="position:fixed;inset:0">
          <p>Sign in and subscribe to our newsletter.</p>
          <input type="password"><button>Sign in</button>
        </div>
        </body></html>
        """
        XCTAssertEqual(
            evaluate("document.querySelector('#login').dataset.lunaSuppressed || 'visible'", html: html),
            "visible")
    }

    /// An email-capture overlay with NO recognizable newsletter phrasing (just an
    /// email field + a generic CTA) is still suppressed — the email input with no
    /// password/OTP is the general signal. This is the Business Insider case: an
    /// email-capture modal whose copy matched none of the text patterns.
    func testEmailCaptureOverlayWithoutNewsletterCopyIsHidden() {
        let html = """
        <html><body>
        <article><p>Publisher content remains readable.</p></article>
        <div id="capture" class="modal" role="dialog" style="position:fixed;inset:0">
          <p>Get the inside scoop.</p>
          <input type="email" placeholder="you@example.com"><button>Continue</button>
        </div>
        </body></html>
        """
        XCTAssertEqual(
            evaluate("document.querySelector('#capture').dataset.lunaSuppressed || 'visible'", html: html),
            "popover")
    }

    /// The email heuristic must not fire on a login/checkout dialog that happens to
    /// carry an email field alongside a password — that is a protected dialog.
    func testLoginDialogWithEmailAndPasswordIsPreserved() {
        let html = """
        <html><body>
        <div id="signin" class="modal" role="dialog" style="position:fixed;inset:0">
          <p>Welcome back.</p>
          <input type="email"><input type="password"><button>Log in</button>
        </div>
        </body></html>
        """
        XCTAssertEqual(
            evaluate("document.querySelector('#signin').dataset.lunaSuppressed || 'visible'", html: html),
            "visible")
    }

    func testPopoverOpenedByImmediateUserActionIsPreserved() {
        let html = "<html><body><button id='open'>Open preferences</button></body></html>"
        let expression = """
        (function () {
          document.querySelector('#open').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
          var modal = document.createElement('div');
          modal.id = 'user-modal'; modal.className = 'newsletter-modal';
          modal.setAttribute('role', 'dialog'); modal.style.cssText = 'position:fixed;inset:0';
          modal.textContent = 'Subscribe to our newsletter'; document.body.appendChild(modal);
          window.__lunaSuppressAnnoyancesNow();
          return modal.dataset.lunaSuppressed || 'visible';
        }())
        """
        XCTAssertEqual(evaluate(expression, html: html), "visible")
    }

    /// The document itself is never an annoyance. Consent vendors put transient
    /// modal/overlay STATE classes on <body> (this fixture mirrors NYT, whose Ethyca
    /// Fides integration adds `fides-overlay-modal-link-shown`), which makes <body>
    /// match the substring `[class*="overlay" i]` overlay probe — and a publisher page
    /// always carries cookie wording plus a reject button somewhere inside it. Hiding
    /// that "consent root" blanked the whole page after first paint. The real banner
    /// must be the one that gets hidden.
    func testDocumentBodyIsNeverTreatedAsTheConsentRoot() {
        let html = """
        <html><body class="gps-show fides-overlay-modal-link-shown fides-no-scroll">
        <div id="fides-overlay" class="fides-overlay">
          <div class="fides-banner">
            <p>We and our vendors use cookies and similar methods to recognize visitors.</p>
            <button class="fides-accept-all-button">Accept all</button>
            <button class="fides-reject-all-button"
                    onclick="document.documentElement.dataset.choice='rejected'">Reject all</button>
          </div>
        </div>
        <main id="site-content">
          <article><p>The full article body must survive annoyance suppression.</p></article>
        </main>
        </body></html>
        """
        let expression = """
        (function () {
          return [document.body.dataset.lunaSuppressed || 'visible',
                  document.querySelector('#fides-overlay').dataset.lunaSuppressed || 'visible',
                  document.querySelector('#site-content') ? 'content' : 'gone',
                  document.documentElement.dataset.choice || 'none'].join('|');
        }())
        """
        XCTAssertEqual(evaluate(expression, html: html), "visible|consent|content|rejected")
    }

    // MARK: - Pinned nag bars

    /// A page whose viewport is filled the way a phone's is, so a bar's height maps
    /// to the same fraction of the screen the production heuristics measure.
    private static func pinnedBarPage(_ bar: String) -> String {
        """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        </head><body style="margin:0">
        <main><article><p>The story must survive whatever is pinned over it.</p></article></main>
        \(bar)
        </body></html>
        """
    }

    /// Forces the pass rather than waiting out the sweep's throttle timer.
    private static let suppressedState = """
    (function () {
      window.__lunaSuppressAnnoyancesNow();
      return [document.querySelector('#bar').dataset.lunaSuppressed || 'visible',
              document.querySelector('article') ? 'content' : 'gone'].join('|');
    }())
    """

    /// The Forbes case. A subscription ribbon is held against the bottom of the
    /// viewport for the whole article, but nothing about it is findable by name —
    /// its class is "ribbon red", which matches no overlay probe — and at 90pt it
    /// covers far too little of the screen for the area gate. It is reached by
    /// hit-testing the viewport edges, and recognized by what it ASKS.
    func testPinnedSubscriptionRibbonIsHidden() {
        let html = Self.pinnedBarPage("""
        <div id="bar" class="ribbon red"
             style="position:fixed;left:0;right:0;bottom:0;height:90px;background:#c00">
          <p>Less than $2/week. Become a Forbes Member.</p>
          <a href="/subscribe">Subscribe Now</a>
        </div>
        """)
        XCTAssertEqual(evaluate(Self.suppressedState, html: html), "popover|content")
    }

    /// The other half of the same rule, and the line this layer does not cross: an
    /// ad slot in the identical position, the identical size, pinned just as hard.
    /// It carries no ask, so nothing hides it — a publisher keeps its advertising.
    func testPinnedAdBarInTheSamePositionIsPreserved() {
        let html = Self.pinnedBarPage("""
        <div id="bar" class="ad-slot mobile-sticky"
             style="position:fixed;left:0;right:0;bottom:0;height:90px">
          <iframe src="about:blank" title="advertisement"></iframe>
        </div>
        """)
        XCTAssertEqual(evaluate(Self.suppressedState, html: html), "visible|content")
    }

    /// A publisher's pinned header sells things — "subscribe to our newsletter"
    /// sits in the masthead of half the web. Hiding it would take the site's own
    /// navigation away with it, so site chrome is exempt however it reads.
    func testPinnedSiteHeaderWithMarketingCopyIsPreserved() {
        let html = Self.pinnedBarPage("""
        <header id="bar" style="position:fixed;left:0;right:0;top:0;height:90px">
          <nav><a href="/news">News</a> <a href="/tech">Tech</a></nav>
          <p>Subscribe to our newsletter.</p>
        </header>
        """)
        XCTAssertEqual(evaluate(Self.suppressedState, html: html), "visible|content")
    }

    /// The menu PANEL is the harder half: a nameless div inside the header, opened
    /// over the whole viewport, whose copy reads like a nag because a masthead menu
    /// always carries one. What separates it from a ribbon rendered in the same
    /// header is that it is a cluster of links — it navigates.
    func testHeaderMenuPanelIsPreservedEvenThoughItReadsLikeANag() {
        let html = Self.pinnedBarPage("""
        <header>
          <div id="bar" style="position:fixed;inset:0">
            <a href="/news">News</a> <a href="/tech">Tech</a>
            <a href="/money">Money</a> <a href="/life">Life</a>
            <p>Become a member. Get unlimited access.</p>
          </div>
        </header>
        """)
        XCTAssertEqual(evaluate(Self.suppressedState, html: html), "visible|content")
    }

    /// A ribbon a publisher renders INSIDE its header is still a ribbon. It asks
    /// one thing and links once, so the link cluster that exempts a menu does not
    /// exempt it.
    func testSubscriptionRibbonInsideTheHeaderIsStillHidden() {
        let html = Self.pinnedBarPage("""
        <header>
          <div id="bar" class="promo"
               style="position:fixed;left:0;right:0;bottom:0;height:90px">
            <p>Become a member for less than $2 a week.</p>
            <a href="/subscribe">Subscribe</a>
          </div>
        </header>
        """)
        XCTAssertEqual(evaluate(Self.suppressedState, html: html), "popover|content")
    }

    /// The edge sweep must not become a back door around "Decline cookies for me".
    /// A consent banner is very often a bar pinned to the bottom of the viewport —
    /// exactly the shape the sweep hunts — so with the gate OFF, the pass that finds
    /// nag bars has to leave this one alone and let the user answer it themselves.
    func testPinnedConsentBannerIsLeftAloneWithCookieAutoDeclineOff() {
        let html = Self.pinnedBarPage("""
        <div id="bar" class="cookie-consent"
             style="position:fixed;left:0;right:0;bottom:0;height:90px">
          <p>We use cookies. Subscribe to our newsletter too.</p>
          <button>Accept all</button>
          <button onclick="document.body.dataset.choice='refused'">Reject all</button>
        </div>
        """)
        XCTAssertEqual(
            evaluate(Self.suppressedState, html: html, cookieAutoDecline: false),
            "visible|content")
    }

    /// The bar rule is about what takes the screen, not about anything positioned.
    /// A reading-progress rule is pinned and full width and must stay.
    func testThinPinnedProgressBarIsNotAnOverlay() {
        let html = Self.pinnedBarPage("""
        <div id="bar" class="progress"
             style="position:fixed;left:0;right:0;top:0;height:4px;background:#0a0">
          <span>Become a member</span>
        </div>
        """)
        XCTAssertEqual(evaluate(Self.suppressedState, html: html), "visible|content")
    }

    // MARK: - The cookie auto-decline gate

    /// The shipped default, with the production stylesheet in the page: the banner
    /// is not painted, Luna answered it, and the revert attribute is absent.
    func testWithTheDefaultGateTheBannerIsDeclinedAndNeverPainted() {
        XCTAssertEqual(
            evaluate(Self.gateReport, html: Self.styledOneTrustPage),
            "none|consent|rejected|1|true|false|content")
    }

    /// "Decline cookies for me" off. The declarative pre-paint hide is what makes a
    /// consent dialog invisible, so switching the feature off has to switch THAT
    /// off too — one attribute on <html> that every consent selector in
    /// annoyances.css is keyed on. The dialog is painted, untouched, unclicked, and
    /// the site has heard nothing from Luna.
    func testWithCookieAutoDeclineOffTheBannerIsPaintedAndLeftAlone() {
        XCTAssertEqual(
            evaluate(Self.gateReport, html: Self.styledOneTrustPage, cookieAutoDecline: false),
            "block|untouched|none|0|false|true|content")
    }

    /// The relay is asynchronous, so an `off` answer can land after the script has
    /// already hidden a banner it found at document_start. It must still end up
    /// answerable: the attribute goes on AND the hidden class comes off.
    func testALateOffAnswerRevealsWhatWasAlreadyHidden() {
        let expression = """
        (function () {
          var banner = document.querySelector('#onetrust-banner-sdk');
          var before = getComputedStyle(banner).display;
          window.__lunaSetCookieAutoDecline(false);
          return [before, getComputedStyle(banner).display,
                  banner.dataset.lunaSuppressed || 'untouched',
                  String(banner.classList.contains('luna-annoyance-hidden'))].join('|');
        }())
        """
        XCTAssertEqual(
            evaluate(expression, html: Self.styledOneTrustPage),
            "none|block|untouched|false")
    }

    /// The gate is CONSENT only, ON THE SAME PAGE. A recognized consent root
    /// normally ends the pass — the consent path is acting on that subtree — but
    /// with the gate off nothing is acting on it, so ending there would exempt every
    /// other annoyance on any page that merely CONTAINS a cookie dialog. The dialog
    /// is excluded by identity instead; the newsletter overlay beside it is not.
    func testTheGateDoesNotReachNonConsentAnnoyancesOnTheSamePage() {
        let html = """
        <html><body>
        <article><p>Publisher content remains readable.</p></article>
        <div id="cookie-consent-bar">
          <p>We use cookies.</p>
          <button onclick="document.body.dataset.choice='accepted'">Accept all</button>
          <button onclick="document.body.dataset.choice='refused'">Reject all</button>
        </div>
        <div id="newsletter" class="newsletter-modal" role="dialog"
             style="position:fixed;inset:0">
          <p>Subscribe to our newsletter</p><button>Not now</button>
        </div>
        </body></html>
        """
        let expression = """
        (function () {
          return [document.querySelector('#cookie-consent-bar').dataset.lunaSuppressed
                    || 'visible',
                  document.body.dataset.choice || 'none',
                  document.querySelector('#newsletter').dataset.lunaSuppressed
                    || 'visible'].join('|');
        }())
        """
        XCTAssertEqual(
            evaluate(expression, html: html, cookieAutoDecline: false),
            "visible|none|popover")
        // With the gate on, the consent path owns the BANNER — refused and hidden —
        // and `scan` still ends its pass there rather than second-guessing what else
        // sits on top of it. The newsletter overlay is reached anyway, by the
        // viewport-edge sweep, which is a separate pass over what actually covers
        // the reader and does not care where the scan stopped. That is the answer
        // this page should give either way round: whether a newsletter modal gets
        // suppressed is not a thing the cookie setting should decide. The sweep
        // still skips consent UI itself (`considerEdgeElement` re-checks
        // `semanticConsentRoot`), so nothing here reconsiders the banner.
        XCTAssertEqual(evaluate(expression, html: html), "consent|refused|popover")
    }

    // MARK: - What counts as a refusal

    /// The label pass is exact-match by design, so its coverage IS its label list.
    /// One row per language rather than per phrase; the accept button next to it
    /// must never be the one that fires.
    func testExactLocalizedRefusalLabelsAreChosen() {
        let labels = [
            "Reject all cookies", "Disagree", "Continue without accepting",
            "Refuser tous les cookies", "Nur notwendige", "Rechazar todas",
            "Rifiuta tutti i cookie", "Alles afwijzen", "Rejeitar tudo",
            "Odrzuć wszystkie", "Afvis alle", "Endast nödvändiga", "Avvis alle",
        ]
        for label in labels {
            let html = """
            <html><body>
            <div id="cookie-consent-panel" role="dialog" aria-modal="true">
              <p>This site uses cookies.</p>
              <button onclick="document.body.dataset.choice='accepted'">Accept all</button>
              <button onclick="document.body.dataset.choice='refused'">\(label)</button>
            </div>
            </body></html>
            """
            XCTAssertEqual(
                evaluate("document.body.dataset.choice || 'none'", html: html), "refused",
                "\(label) is not chosen as a refusal")
        }
    }

    /// A CMP's own documented reject control, for the two whose visible label is
    /// not itself a refusal phrase — so only the selector can find it.
    func testCMPSpecificRejectSelectorsAreChosen() {
        let fixtures = [
            (
                "TrustArc",
                """
                <div id="trustarc-banner-container">
                  <p>We use cookies.</p>
                  <button id="truste-consent-button">Agree and proceed</button>
                  <button id="truste-consent-required"
                          onclick="document.body.dataset.choice='refused'">Required only</button>
                </div>
                """
            ),
            (
                // Sourcepoint's first layer, as seen from INSIDE its own
                // `sp_message_iframe_*` frame (annoyances.js runs in all frames).
                "Sourcepoint",
                """
                <div id="sp_message_container_482">
                  <div class="message-container">
                    <p>Your cookie choices.</p>
                    <button title="Accept All">Continue</button>
                    <button title="Reject All"
                            onclick="document.body.dataset.choice='refused'">Manage</button>
                  </div>
                </div>
                """
            ),
        ]
        for (name, markup) in fixtures {
            XCTAssertEqual(
                evaluate(
                    "document.body.dataset.choice || 'none'",
                    html: "<html><body>\(markup)</body></html>"),
                "refused", "\(name)'s reject control was not chosen")
        }
    }

    /// A first layer with no reject button at all. Only NAMED flows are attempted,
    /// and only that CMP's own refuse-all control is clicked at the far end —
    /// nothing here hunts a preference centre for a plausible-looking button.
    func testOneTrustSettingsPaneIsOpenedToReachRefuseAll() {
        let html = """
        <html><body>
        <div id="onetrust-consent-sdk">
          <div id="onetrust-banner-sdk">
            <p>We use cookies to personalize content.</p>
            <button id="onetrust-accept-btn-handler">Accept all</button>
            <button id="onetrust-pc-btn-handler" onclick="openPanel()">Cookie Settings</button>
          </div>
        </div>
        <script>
        function openPanel() {
          var panel = document.createElement('div');
          panel.id = 'onetrust-pc-sdk';
          panel.innerHTML =
            '<button class="ot-pc-refuse-all-handler"'
            + ' onclick="document.body.dataset.choice=\\'refused\\'">Reject All</button>';
          document.body.appendChild(panel);
        }
        </script>
        </body></html>
        """
        let expression = """
        (function () {
          return [document.body.dataset.choice || 'none',
                  String(window.__lunaAnnoyanceStats().twoStepFlows),
                  String(window.__lunaAnnoyanceStats().consentChoices)].join('|');
        }())
        """
        XCTAssertEqual(evaluate(expression, html: html), "refused|1|1")
    }

    /// The veto, checked at the single click sink rather than trusted per source: a
    /// publisher who put a CMP's reject id on an ACCEPT button gets no click at all.
    /// The notice is still hidden — Luna just refuses to answer for the user.
    func testAControlThatReadsAsAcceptIsNeverClicked() {
        let html = """
        <html><body>
        <div id="cookie-banner-root">
          <p>We use cookies.</p>
          <button id="onetrust-reject-all-handler"
                  onclick="document.body.dataset.choice='accepted'">Accept all cookies</button>
        </div>
        <main><article><p>Story.</p></article></main>
        </body></html>
        """
        let expression = """
        (function () {
          return [document.body.dataset.choice || 'none',
                  String(window.__lunaAnnoyanceStats().consentChoices),
                  document.querySelector('#cookie-banner-root').dataset.lunaSuppressed
                    || 'visible'].join('|');
        }())
        """
        XCTAssertEqual(evaluate(expression, html: html), "none|0|consent")
    }

    /// The same invariant one level down: a wrapper is not an annoyance just because
    /// its name reads like one, when it holds the page's main content.
    func testContentWrapperNamedLikeAnOverlayIsPreserved() {
        let html = """
        <html><body>
        <div id="shell" class="page-overlay" style="position:fixed;inset:0">
          <p>Subscribe to our newsletter for cookie-free updates.</p>
          <main><article><p>The article body lives inside the wrapper.</p></article></main>
        </div>
        </body></html>
        """
        XCTAssertEqual(
            evaluate("document.querySelector('#shell').dataset.lunaSuppressed || 'visible'", html: html),
            "visible")
    }
}

/// The cookie auto-decline switch, as a CONTRACT between three processes that
/// share no code: the app writes an App-Group key, the Safari appex reads it as a
/// bare literal (it links no app code), and the page acts on the answer — which
/// can only reach a content script through background.js. A key, a message name or
/// a reply field that agrees on two sides out of three is a setting that silently
/// does nothing, and nothing but a source-text pin can see across all four files.
final class SafariAnnoyanceGateContractTests: XCTestCase {

    private static func source(_ relativePath: String) -> String {
        SafariJSSource.read(relativePath)
    }

    private var annoyances: String { Self.source("LunaSafari/Resources/annoyances.js") }
    private var background: String { Self.source("LunaSafari/Resources/background.js") }
    private var handler: String { Self.source("LunaSafari/SafariWebExtensionHandler.swift") }

    func testTheGateIsOneKeyOneMessageAndOneReplyFieldAcrossEveryProcess() {
        XCTAssertTrue(
            handler.contains("\"\(SafariSuggestionSettings.cookieAutoDeclineKey)\""),
            "the Safari handler reads a different App Group key than Settings writes")
        for (name, source) in [
            ("annoyances.js", annoyances), ("background.js", background),
            ("SafariWebExtensionHandler.swift", handler),
        ] {
            XCTAssertTrue(
                source.contains("annoyanceSettings"),
                "\(name) does not name the annoyanceSettings message — a content script "
                    + "reaches the native handler only if all three sides do")
        }
        XCTAssertTrue(
            annoyances.contains("resp.cookieAutoDecline === false"),
            "annoyances.js no longer reads the reply field the handler sends")
        XCTAssertTrue(
            background.contains("cookieAutoDecline:"),
            "the background relay drops cookieAutoDecline — its replies are explicit "
                + "allow-lists, so a field missing here never reaches the page")
        XCTAssertTrue(
            handler.contains("payload[\"cookieAutoDecline\"]"),
            "the handler stopped sending the answer annoyances.js waits for")
    }

    /// The key lives in the suite all four apps share, and only the two ARTICLE
    /// apps expose the control — so a non-article host must not read it at all, or
    /// a Reader "off" would silence the Downloader's and Price Tracker's always-on
    /// suppression too. Same shape as the `mode` gate beside it.
    func testANonArticleHostIsAnsweredTrueWithoutReadingTheSharedKey() {
        let assignment = handler
            .components(separatedBy: "payload[\"cookieAutoDecline\"]").last ?? ""
        XCTAssertTrue(
            assignment.prefix(400).contains("hostHandlesArticles"),
            "the handler answers cookieAutoDecline without gating on hostHandlesArticles — "
                + "the Downloader and Price Tracker would inherit an article app's choice")
    }
}

