//
//  SafariAnnoyanceSuppressionTests.swift
//  LunaTests
//

import XCTest

/// Exercises the document-start annoyance script in the shared bare-`WKWebView`
/// harness (`SafariJSTestHarness`). These fixtures focus on the safety boundary:
/// consent is rejected, true popovers are hidden, and inline ads / user-critical
/// dialogs are left alone.
@MainActor
final class SafariAnnoyanceSuppressionTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    private func evaluate(_ expression: String, html: String) -> String? {
        js.load(
            html: html, urlString: "https://example.com/story",
            scripts: [SafariJSTestHarness.annoyances])
        return js.string(expression)
    }

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
