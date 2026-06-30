//
//  WebJunkBlocker.swift
//  Lune
//

import WebKit

/// Keeps the inline web preview readable on ad-/donation-/consent-heavy sites:
/// a content rule list hides common overlay/banner elements and blocks the
/// usual consent/ad scripts, and an injected script removes anything
/// fixed-position covering a large share of the viewport and re-enables body
/// scrolling (sites lock it while a modal is up).
public enum WebJunkBlocker {

    private static let ruleListIdentifier = "lune-web-junk-v1"

    private static let rulesJSON = """
    [
      {
        "trigger": { "url-filter": ".*" },
        "action": {
          "type": "css-display-none",
          "selector": "[class*='paywall'],[id*='paywall'],[class*='popup'],[id*='popup'],[class*='consent'],[id*='consent'],[class*='cookie-banner'],[id*='cookie-banner'],[class*='newsletter'],[class*='donate'],[id*='donate'],[class*='gdpr'],[id*='gdpr'],[class*='interstitial'],[class*='subscribe-banner'],[class*='piano'],[id*='piano'],[class*='fc-consent'],[id*='onetrust'],[class*='onetrust'],[id*='sp_message'],[class*='sp_message']"
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

    /// One shared web content process pool across every junk-blocking web view, so a
    /// second web view (e.g. a cache-miss inline link, or the Original mode switch)
    /// reuses the already-warm web process instead of cold-starting its own.
    private static let sharedProcessPool = WKProcessPool()

    /// A web view configuration with the cleanup script pre-installed and the shared
    /// process pool attached.
    public static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = sharedProcessPool
        let script = WKUserScript(
            source: cleanupJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(script)
        return configuration
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
            ) { compiled, _ in
                if let compiled {
                    controller.add(compiled)
                }
            }
        }
    }
}
