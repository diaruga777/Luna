//
//  PaywallUnlockRules.swift
//  ReaderKit
//

import Foundation
import WebKit

/// The iOS port of Bypass-Paywalls-Clean's two iOS-applicable primitives, used by
/// the `.directUnlock` WKWebView strategy (only when the user opts into
/// `ReaderSettings.nonArchiveBypassEnabled`):
///
///  1. A compiled `WKContentRuleList` that **blocks the paywall/meter vendor
///     scripts** (Piano/tinypass, Evolok, Zephr, Poool, Pelcro, Pico, Wallkit,
///     Sophi, Qiota, Cxense, …). Blocking these lets a site's own JS render the
///     full article while the meter can't run — the single highest-ROL technique,
///     since one vendor block covers every site that uses that vendor.
///  2. An injected **DOM-cleanup userscript** that removes leftover paywall
///     overlays, unhides the clamped/blurred article body, restores page scroll,
///     and un-lazies images — ported from BPC's general (non-site-specific)
///     cleanup. Guarded to never touch the archive.today reader.
///
/// Plus the BPC **list of supported hosts**, used (toggle-on only) to recognize a
/// paywalled site the generic gate didn't flag, so it still gets the unlock flow.
///
/// All of this is inert unless the experimental toggle is on (it only feeds the
/// `.directUnlock` strategy, which the selector emits only when the toggle is on).
/// Pure data + a compile helper; the rule JSON / cleanup JS are unit-tested.
enum PaywallUnlockRules {

    // MARK: - Content-blocker (vendor paywall/meter scripts)

    /// One blockable vendor: a host substring matched against request URLs, the
    /// WebKit resource types to block, and domains to EXEMPT (BPC `@@` exceptions /
    /// sites that need the vendor for their own content).
    private struct VendorBlock {
        let host: String
        var resourceTypes: [String] = ["script", "raw"]
        var unlessDomains: [String] = []
    }

    /// The "General" paywall/meter vendors from `bpc-paywall-filter.txt`. Blocking
    /// their scripts (and XHR via `raw`) defeats the metering on every site that
    /// embeds them.
    private static let vendorBlocks: [VendorBlock] = [
        VendorBlock(host: "piano.io", unlessDomains: ["hbr.org", "japantimes.co.jp"]),
        VendorBlock(host: "tinypass.com", unlessDomains: ["ajc.com", "thelogic.co"]),
        VendorBlock(host: "evolok.net"),
        VendorBlock(host: "zephr.com"),
        // Cxense: WSJ/Quebecor need it for their own content, per BPC.
        VendorBlock(host: "cxense.com",
                    unlessDomains: ["wsj.com", "journaldemontreal.com", "journaldequebec.com"]),
        VendorBlock(host: "qiota.com"),
        VendorBlock(host: "sophi.io"),
        VendorBlock(host: "poool.fr"),
        VendorBlock(host: "fewcents.co"),
        VendorBlock(host: "pelcro.com"),
        VendorBlock(host: "pico.tools"),
        VendorBlock(host: "wallkit.net"),
        VendorBlock(host: "hadrianpaywall.com"),
        VendorBlock(host: "steadyhq.com"),
        VendorBlock(host: "onecount.net"),
        VendorBlock(host: "olytics.omeda.com"),
        VendorBlock(host: "matheranalytics.com"),
        VendorBlock(host: "newsmemory.com"),
        VendorBlock(host: "blueconic.net"),
        VendorBlock(host: "axate.io"),
        VendorBlock(host: "ensighten.com"),
        VendorBlock(host: "getsitecontrol.com"),
        VendorBlock(host: "amplitude.com", resourceTypes: ["raw"]),
    ]

    /// Path-based blocks (vendor scripts served from the publisher's own host).
    private struct PathBlock {
        let pattern: String   // url-filter regex fragment (already escaped)
        var resourceTypes: [String] = ["script"]
    }
    private static let pathBlocks: [PathBlock] = [
        PathBlock(pattern: "/wp-content/plugins/leaky-paywall/"),
        PathBlock(pattern: "/wp-json/leaky-paywall/", resourceTypes: ["raw"]),
        PathBlock(pattern: "-gate-metering"),
    ]

    static let contentRuleListIdentifier = "clip-paywall-vendor-block-v1"

    /// The `WKContentRuleList` JSON: one block rule per vendor/path. `url-filter`
    /// is anchored to a host boundary so `piano.io` can't match `piano.io.evil.com`.
    static var contentRuleListJSON: String {
        var rules: [String] = []
        for vendor in vendorBlocks {
            let escapedHost = vendor.host.replacingOccurrences(of: ".", with: "\\\\.")
            // scheme://(sub.)*host followed by a port/path boundary. WKContentRuleList's
            // url-filter is a LIMITED regex subset — no `\w`/`\d`, so use explicit
            // character classes for the optional subdomain labels.
            let filter = "https?://([a-z0-9-]+\\\\.)*\(escapedHost)[:/]"
            var trigger = "\"url-filter\":\"\(filter)\",\"resource-type\":\(jsonArray(vendor.resourceTypes))"
            if !vendor.unlessDomains.isEmpty {
                // WebKit's `unless-domain` matches the EXACT document domain unless an
                // entry is `*`-prefixed (then it covers the domain + its subdomains).
                // Publishers are usually on `www.`, so prefix every exemption with `*`.
                trigger += ",\"unless-domain\":\(jsonArray(vendor.unlessDomains.map { "*" + $0 }))"
            }
            rules.append("{\"trigger\":{\(trigger)},\"action\":{\"type\":\"block\"}}")
        }
        for path in pathBlocks {
            let filter = path.pattern.replacingOccurrences(of: ".", with: "\\\\.")
            rules.append(
                "{\"trigger\":{\"url-filter\":\"\(filter)\",\"resource-type\":\(jsonArray(path.resourceTypes))},"
                + "\"action\":{\"type\":\"block\"}}")
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    private static func jsonArray(_ values: [String]) -> String {
        "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// Compiles (and caches) the content rule list. Calls back on the main thread.
    private static var cachedRuleList: WKContentRuleList?
    static func compiledRuleList(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let cachedRuleList {
            completion(cachedRuleList)
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: contentRuleListIdentifier, encodedContentRuleList: contentRuleListJSON
        ) { list, error in
            if let error {
                SharedDiagnosticLog.record(
                    "paywall rules compile error: \(error.localizedDescription)", category: "archive")
            }
            // Only cache a successful compile so a transient failure can retry.
            if let list { cachedRuleList = list }
            DispatchQueue.main.async { completion(list) }
        }
    }

    // MARK: - DOM cleanup userscript

    /// Injected at documentStart; re-runs on an interval (covering the reader's poll
    /// window) to strip paywall overlays, unhide the article, and restore scroll.
    /// NEVER runs on the archive.today reader (it would fight the CAPTCHA flow).
    static let domCleanupScript = """
    (function () {
      try {
        var h = (location.hostname || '').toLowerCase();
        if (/(^|\\.)archive\\.(is|today|ph|md|li|vn|fo)$/.test(h)) { return; }
        var REMOVE = [
          'div.paywall', 'div.paywall-content', 'div.meteredContent', 'div#full-paywall',
          'aside#paywall', 'div.subscription-wall', 'div#tp-regwall', 'div#tp-modal',
          'div.snippet-promotion', '.snippet-promotion', 'div[id*="-snippet-overlay"]',
          'div.modal-backdrop', 'div[class^="Modal_paywall"]', 'div[class^="Modal_cta"]',
          'div[class*="subscribe-wall"]', 'div[class*="regwall"]', 'div.tp-modal',
          'div[data-testid*="paywall"]', 'div[class*="PaywallOverlay"]', 'div.piano-template'
        ];
        var UNHIDE = ['blurred','blur','blur-sm','blur-md','blur-lg','gradient','fade','faded-content',
          'clipped','cropped','truncated','locked','is-locked','noscroll','no-scroll','scroll-lock',
          'overflow-hidden','modal-open'];
        function clean() {
          try {
            REMOVE.forEach(function (sel) {
              document.querySelectorAll(sel).forEach(function (el) { el.remove(); });
            });
            [document.documentElement, document.body].forEach(function (el) {
              if (!el) { return; }
              el.style.overflow = ''; el.style.position = ''; el.style.height = '';
              UNHIDE.forEach(function (c) { if (el.classList) { el.classList.remove(c); } });
            });
            if (document.documentElement) { document.documentElement.style.overflow = 'auto'; }
            UNHIDE.forEach(function (c) {
              document.querySelectorAll('.' + c).forEach(function (el) {
                el.classList.remove(c);
                el.style.filter = 'none'; el.style.webkitFilter = 'none';
                el.style.maxHeight = 'none'; el.style.overflow = 'visible'; el.style.webkitMaskImage = 'none';
              });
            });
            document.querySelectorAll('img[data-src]').forEach(function (i) {
              if (!i.src || i.src.indexOf('data:') === 0) { i.src = i.getAttribute('data-src'); }
            });
            document.querySelectorAll('img[currentsourceurl]').forEach(function (i) {
              i.src = i.getAttribute('currentsourceurl');
            });
            document.querySelectorAll('[style*="visibility:hidden"],[style*="visibility: hidden"]')
              .forEach(function (e) { e.style.visibility = 'visible'; });
          } catch (e) {}
        }
        clean();
        var n = 0;
        var t = setInterval(function () { clean(); if (++n > 20) { clearInterval(t); } }, 700);
        document.addEventListener('DOMContentLoaded', clean);
      } catch (e) {}
    })();
    """

    static func cleanupUserScript() -> WKUserScript {
        WKUserScript(source: domCleanupScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // MARK: - Known paywalled hosts (BPC supported-sites list)

    /// Whether `url`'s host is a Bypass-Paywalls-Clean supported paywall host. Used
    /// ONLY when the toggle is on, to let a site the generic gate didn't flag still
    /// enter the unlock flow. Matches apex + any subdomain (trailing dot tolerated).
    static func isKnownPaywallHost(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        return supportedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Base domains BPC supports (a representative cross-section of its list — USA
    /// national/business/tech/magazines, the big publisher groups, UK/EU, and a few
    /// AU/Asia). Used only as an extra toggle-on paywall signal; duplicates with
    /// `NewsSites.hardPaywall` are harmless.
    static let supportedHosts: Set<String> = [
        // USA national / business
        "wsj.com", "nytimes.com", "washingtonpost.com", "bloomberg.com", "reuters.com",
        "barrons.com", "businessinsider.com", "cnbc.com", "forbes.com", "fortune.com",
        "marketwatch.com", "hbr.org", "inc.com", "fastcompany.com", "entrepreneur.com",
        "adweek.com", "benzinga.com", "investors.com", "law.com", "qz.com", "spglobal.com",
        "citywire.com", "thestreet.com", "morningstar.com", "ft.com", "economist.com",
        // Arizent / Crain groups
        "americanbanker.com", "accountingtoday.com", "bondbuyer.com", "financial-planning.com",
        "nationalmortgagenews.com", "adage.com", "autonews.com", "chicagobusiness.com",
        "crainsnewyork.com", "crainsdetroit.com", "modernhealthcare.com", "pionline.com",
        "plasticsnews.com", "bizjournals.com",
        // Tech / science
        "wired.com", "technologyreview.com", "nationalgeographic.com", "nature.com",
        "newscientist.com", "popsci.com", "science.org", "sciencenews.org",
        "scientificamerican.com", "the-scientist.com", "tomshardware.com", "discovermagazine.com",
        "interestingengineering.com", "medscape.com", "insidehighered.com", "timeshighereducation.com",
        // Magazines / blogs
        "theatlantic.com", "thedailybeast.com", "foreignaffairs.com", "foreignpolicy.com",
        "harpers.org", "newsweek.com", "politico.com", "slate.com", "thenation.com",
        "newrepublic.com", "nybooks.com", "theweek.com", "vice.com", "al-monitor.com",
        "axios.com", "theamericanconservative.com", "pastemagazine.com",
        // Condé Nast
        "architecturaldigest.com", "bonappetit.com", "cntraveler.com", "epicurious.com",
        "gq.com", "newyorker.com", "vanityfair.com", "vogue.com",
        // Hearst
        "cosmopolitan.com", "elle.com", "elledecor.com", "esquire.com", "goodhousekeeping.com",
        "harpersbazaar.com", "housebeautiful.com", "menshealth.com", "popularmechanics.com",
        "prevention.com", "roadandtrack.com", "runnersworld.com", "townandcountrymag.com",
        "womenshealthmag.com", "bicycling.com", "delish.com", "oprahdaily.com",
        // Penske / Vox / others
        "billboard.com", "rollingstone.com", "variety.com", "wwd.com", "sportico.com",
        "nymag.com", "thecut.com", "theverge.com", "vox.com", "vulture.com", "curbed.com",
        // USA local + groups
        "latimes.com", "bostonglobe.com", "seattletimes.com", "nydailynews.com", "nypost.com",
        "ajc.com", "azcentral.com", "cincinnati.com", "courier-journal.com", "desmoinesregister.com",
        "detroitnews.com", "dispatch.com", "freep.com", "indystar.com", "jsonline.com",
        "northjersey.com", "tennessean.com", "baltimoresun.com", "chicagotribune.com",
        "courant.com", "orlandosentinel.com", "sun-sentinel.com", "mcall.com",
        // Canada
        "theglobeandmail.com", "ledevoir.com", "thelogic.co", "winnipegfreepress.com",
        // UK / Ireland
        "telegraph.co.uk", "thetimes.com", "observer.co.uk", "irishexaminer.com",
        "decanter.com", "fnlondon.com", "lrb.co.uk", "newstatesman.com", "spectator.co.uk",
        // Europe
        "spiegel.de", "faz.net", "sueddeutsche.de", "handelsblatt.com", "welt.de", "zeit.de",
        "lemonde.fr", "lefigaro.fr", "lexpress.fr", "lepoint.fr", "liberation.fr",
        "elpais.com", "elmundo.es", "elconfidencial.com", "corriere.it", "repubblica.it",
        "ilsole24ore.com", "nrc.nl", "telegraaf.nl",
        // Asia / Australia
        "asia.nikkei.com", "japantimes.co.jp", "thehindu.com", "hindustantimes.com",
        "indianexpress.com", "smh.com.au", "theage.com.au", "afr.com", "nzherald.co.nz",
    ]
}
