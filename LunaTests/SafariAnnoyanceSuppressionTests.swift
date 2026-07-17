//
//  SafariAnnoyanceSuppressionTests.swift
//  LunaTests
//

import WebKit
import XCTest

/// Exercises the document-start annoyance script in a bare WKWebView. These
/// fixtures focus on the safety boundary: consent is rejected, true popovers are
/// hidden, and inline ads / user-critical dialogs are left alone.
@MainActor
final class SafariAnnoyanceSuppressionTests: XCTestCase {

    private static let scriptSource: String = {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("LunaSafari/Resources/annoyances.js")
        return (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
    }()

    override func setUp() {
        super.setUp()
        XCTAssertFalse(Self.scriptSource.isEmpty, "annoyances.js not found relative to #filePath")
    }

    private func evaluate(_ expression: String, html: String) -> String? {
        let expectation = expectation(description: "annoyance script evaluated")
        var outcome: String?
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let delegate = LoadDelegate {
            webView.evaluateJavaScript(Self.scriptSource) { _, scriptError in
                if let scriptError { XCTFail("annoyances.js failed: \(scriptError)") }
                webView.evaluateJavaScript(expression) { result, expressionError in
                    if let expressionError { XCTFail("fixture expression failed: \(expressionError)") }
                    outcome = result as? String
                    expectation.fulfill()
                }
            }
        }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/story"))
        wait(for: [expectation], timeout: 10)
        withExtendedLifetime(delegate) {}
        return outcome
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
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
}
