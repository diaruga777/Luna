//
//  WebJunkBlocker.swift
//  Luna
//

import os
import WebKit

/// Keeps the inline web preview readable on ad-/donation-/consent-heavy sites:
/// a content rule list hides common overlay/banner elements and blocks the
/// usual consent/ad scripts, and an injected script removes anything
/// fixed-position covering a large share of the viewport and re-enables body
/// scrolling (sites lock it while a modal is up).
public enum WebJunkBlocker {

    // Bump whenever `rulesJSON` changes: WebKit persists compiled lists by ID.
    private static let ruleListIdentifier = "luna-web-junk-v2"

    private static let rulesJSON = """
    [
      {
        "trigger": { "url-filter": ".*" },
        "action": {
          "type": "css-display-none",
          "selector": "aside[class*='Paywall'],[role='dialog'][class*='paywall'],[role='dialog'][id*='paywall'],[class*='PaywallOverlay'],[class*='paywall-modal'],[class*='paywall-bar'],[data-testid*='PaywallInlineBarrier'],[class*='popup'],[id*='popup'],[class*='consent'],[id*='consent'],[class*='cookie-banner'],[id*='cookie-banner'],[class*='newsletter'],[class*='donate'],[id*='donate'],[class*='gdpr'],[id*='gdpr'],[class*='interstitial'],[class*='subscribe-banner'],[class*='piano'],[id*='piano'],[class*='fc-consent'],[id*='onetrust'],[class*='onetrust'],[id*='sp_message'],[class*='sp_message']"
        }
      },
      {
        "trigger": {
          "url-filter": ".*",
          "if-domain": ["*doubleclick.net", "*googlesyndication.com", "*adsystem.com", "*taboola.com", "*outbrain.com", "*onetrust.com", "*cookielaw.org", "*quantcast.com", "*piano.io", "*tinypass.com", "*sourcepoint.com", "*privacy-mgmt.com"]
        },
        "action": { "type": "block" }
      }
    ]
    """

    /// Removes large fixed/sticky overlays (donation nags, consent walls) and
    /// unlocks page scrolling. Runs at document end and again as late scripts
    /// inject their overlays.
    private static let cleanupJS = """
    (function () {
      function isBlockingOverlay(el) {
        var style = getComputedStyle(el);
        if (style.position !== 'fixed' && style.position !== 'sticky') { return false; }
        var rect = el.getBoundingClientRect();
        return (rect.width * rect.height) > (window.innerWidth * window.innerHeight * 0.25);
      }
      function clean() {
        try {
          if (!document.body) { return; }
          var candidates = [];
          var children = document.body.children;
          for (var i = 0; i < children.length; i++) {
            candidates.push(children[i]);
            var kids = children[i].children;
            for (var j = 0; j < Math.min(kids.length, 20); j++) { candidates.push(kids[j]); }
          }
          for (var k = 0; k < candidates.length; k++) {
            if (isBlockingOverlay(candidates[k])) { candidates[k].remove(); }
          }
          document.body.style.setProperty('overflow', 'visible', 'important');
          document.documentElement.style.setProperty('overflow', 'visible', 'important');
          if (getComputedStyle(document.body).position === 'fixed') {
            document.body.style.setProperty('position', 'static', 'important');
          }
        } catch (e) {}
      }
      clean();
      setTimeout(clean, 800);
      setTimeout(clean, 2500);
    })();
    """

    /// A web view configuration with the cleanup script pre-installed.
    ///
    /// This used to also hand every junk-blocking web view one shared
    /// `WKProcessPool`, so a second web view (a cache-miss inline link, the
    /// Original mode switch) reused the already-warm web process. Since iOS 15
    /// that pool is documented to have no effect — process sharing follows the
    /// `websiteDataStore` instead, and these configurations all take the
    /// default one — so the pool bought nothing and is gone.
    public static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        addCleanupScript(to: configuration.userContentController)
        return configuration
    }

    /// Installs the synchronous DOM-cleanup half on an existing configuration.
    /// Saved-archive capture/replay combines this with its paywall-specific scripts
    /// before the first navigation.
    public static func addCleanupScript(to controller: WKUserContentController) {
        let script = WKUserScript(
            source: cleanupJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        controller.addUserScript(script)
    }

    /// Compiles (or fetches the cached) rule list and attaches it. Async — the
    /// page may start loading before rules attach; the cleanup script covers
    /// the gap.
    public static func applyRuleList(to controller: WKUserContentController) {
        let store = WKContentRuleListStore.default()
        store?.lookUpContentRuleList(forIdentifier: ruleListIdentifier) { cached, _ in
            if let cached {
                controller.add(cached)
                return
            }
            store?.compileContentRuleList(
                forIdentifier: ruleListIdentifier,
                encodedContentRuleList: rulesJSON
            ) { compiled, error in
                if let compiled {
                    controller.add(compiled)
                } else if let error {
                    // A malformed rulesJSON would otherwise silently disable
                    // all junk blocking.
                    Logger(subsystem: "luna", category: "webjunk")
                        .error("content rule compile failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Async form used when a caller must attach the blocker before navigation.
    /// Main-actor because `WKContentRuleListStore` is; every caller is building
    /// a web view anyway.
    @MainActor
    public static func compiledRuleList() async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            guard let store = WKContentRuleListStore.default() else {
                continuation.resume(returning: nil)
                return
            }
            store.lookUpContentRuleList(forIdentifier: ruleListIdentifier) { cached, _ in
                if let cached {
                    continuation.resume(returning: cached)
                    return
                }
                store.compileContentRuleList(
                    forIdentifier: ruleListIdentifier,
                    encodedContentRuleList: rulesJSON
                ) { compiled, error in
                    if let error {
                        Logger(subsystem: "luna", category: "webjunk")
                            .error("content rule compile failed: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: compiled)
                }
            }
        }
    }
}
