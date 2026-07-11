//
//  PaywallUnlockRules.swift
//  ReaderKit
//

import LunaDesignSystem
import LunaPaywallBypass
import LunaStorage
import LunaURLClassification
import Foundation
import WebKit

/// The WKWebView browser tier of the always-on paywall-unlock engine. Two
/// iOS-applicable primitives,
/// both driven by the bundled per-site rule table (`SiteUnlockRules`):
///
///  1. A compiled `WKContentRuleList` that **blocks the metering/paywall scripts** for
///     the loaded host — the site's own `blockRegex` patterns plus the global vendor
///     blockers (Piano/tinypass, Zephr, Sophi, Cxense, Poool, Pelcro, …). With the
///     meter unable to run, the site's own JS renders the full article, which the
///     reader then extracts.
///  2. An injected **DOM-cleanup userscript** that removes leftover paywall overlays,
///     unhides the clamped/blurred body, restores scroll, un-lazies images, and reveals
///     AMP subscriber sections. Self-guards off archive.today so it never fights the
///     CAPTCHA flow.
///
/// The rule JSON generation and cleanup JS are unit-tested; the compiled list is
/// validated on-simulator.
public enum PaywallUnlockRules {

    // MARK: - Content blocker (metering/paywall scripts, per host)

    /// The WebKit resource types a block rule applies to (script + XHR/fetch).
    private static let blockResourceTypes = "[\"script\",\"raw\"]"

    /// Translates a JS regex source (from the rule table) into the LIMITED regex
    /// subset `WKContentRuleList` accepts for `url-filter`. Returns ZERO OR MORE
    /// filters: WKContentRuleList's `url-filter` does NOT support alternation (`|`) or
    /// grouping, so a pattern like `(a|b)c` is EXPANDED into concrete alternatives
    /// (`ac`, `bc`). Returns `[]` when the pattern uses a construct the subset can't
    /// represent even after expansion (`{n,m}`, backreferences, look-around, `\b`,
    /// group quantifiers) — dropping that one pattern rather than failing the list.
    public static func urlFilters(fromJSRegexSource source: String) -> [String] {
        var s = source
        s = s.replacingOccurrences(of: "\\/", with: "/")        // literal slash
        s = s.replacingOccurrences(of: "\\d", with: "[0-9]")
        s = s.replacingOccurrences(of: "\\w", with: "[a-zA-Z0-9_]")
        s = s.replacingOccurrences(of: "(?:", with: "(")        // non-capturing → capturing
        // Constructs WKContentRuleList's regex engine rejects even after expansion.
        // Group quantifiers (`)?`, `)*`, `)+`, e.g. `(.+-)?`) can't be expanded finitely.
        let unsupported = ["{", "(?=", "(?!", "(?<", "\\b", "\\s", "\\1", "\\2", "\\3", "\\D", "\\W",
                           ")?", ")*", ")+"]
        for token in unsupported where s.contains(token) { return [] }
        // After the conversions above the only backslash escape we allow is `\.`; any
        // other residual `\x` (incl. escaped parens) is unsupported → drop.
        if residualHasUnsafeEscape(s) { return [] }
        // Expand alternations/groups into concrete, alternation-free filters. The
        // cap is enforced INSIDE the expansion (overflow short-circuits), so a
        // pathological (a|b)(c|d)… pattern can't materialize 2^N strings before
        // the count is checked.
        let expanded = expandAlternations(Array(s))
        return expanded.count <= expansionLimit ? expanded : []
    }

    /// Max concrete filters one pattern may expand to; exceeding it drops the pattern.
    static let expansionLimit = 24

    /// Expands a group-and-alternation regex (no group quantifiers, no unsupported
    /// escapes) into the set of concrete alternation-free / group-free strings it
    /// matches structurally. `a(b|c)d` → `["abd","acd"]`. Char classes `[...]` are
    /// treated as opaque (their `|`/`()` are literal, not structural). Stops as
    /// soon as `limit` is exceeded (the over-limit result is a sentinel for the
    /// caller to drop the pattern, never 2^N strings in memory).
    static func expandAlternations(_ chars: [Character], limit: Int = expansionLimit) -> [String] {
        // Top-level `|` → the union of each alternative's expansion.
        let alternatives = splitTopLevel(chars, on: "|")
        if alternatives.count > 1 {
            var out: [String] = []
            for alternative in alternatives {
                out += expandAlternations(alternative, limit: max(limit - out.count, 0))
                if out.count > limit { return out }
            }
            return out
        }
        // A single alternative: expand its first top-level group, if any.
        guard let (open, close) = firstTopLevelGroup(chars) else {
            return [String(chars)]   // no group → already concrete
        }
        let prefix = String(chars[..<open])
        let innerExpansions = expandAlternations(Array(chars[(open + 1)..<close]), limit: limit)
        let suffixExpansions = expandAlternations(Array(chars[(close + 1)...]), limit: limit)
        var out: [String] = []
        for inner in innerExpansions {
            for suffix in suffixExpansions {
                out.append(prefix + inner + suffix)
                if out.count > limit { return out }
            }
        }
        return out
    }

    /// Splits `chars` on `separator` at nesting depth 0, treating `[...]` classes as
    /// opaque.
    private static func splitTopLevel(_ chars: [Character], on separator: Character) -> [[Character]] {
        var parts: [[Character]] = []
        var current: [Character] = []
        var depth = 0
        var inClass = false
        for ch in chars {
            if inClass {
                current.append(ch)
                if ch == "]" { inClass = false }
            } else if ch == "[" {
                inClass = true; current.append(ch)
            } else if ch == "(" {
                depth += 1; current.append(ch)
            } else if ch == ")" {
                depth -= 1; current.append(ch)
            } else if ch == separator, depth == 0 {
                parts.append(current); current = []
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    /// The index range of the first top-level `(...)` group in `chars`, or nil.
    private static func firstTopLevelGroup(_ chars: [Character]) -> (open: Int, close: Int)? {
        var inClass = false
        var open: Int?
        var depth = 0
        for (i, ch) in chars.enumerated() {
            if inClass {
                if ch == "]" { inClass = false }
            } else if ch == "[" {
                inClass = true
            } else if ch == "(" {
                if open == nil { open = i }
                depth += 1
            } else if ch == ")" {
                depth -= 1
                if depth == 0, let start = open { return (start, i) }
            }
        }
        return nil
    }

    /// True if `s` contains a backslash escape other than `\.` (which WKContentRuleList
    /// accepts). Scans backslashes and checks the following char.
    private static func residualHasUnsafeEscape(_ s: String) -> Bool {
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" {
                guard i + 1 < chars.count, chars[i + 1] == "." else { return true }
                i += 2
            } else {
                i += 1
            }
        }
        return false
    }

    /// The block-rule JSON for `url`: the matched site rule's `blockRegex` +
    /// `blockJsInline`, plus every global vendor blocker not excluded for this host.
    /// Patterns the WK subset can't represent are dropped (logged as a count).
    public static func contentRuleListJSON(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        var sources: [String] = []
        if let rule = SiteUnlockRules.rule(for: url) {
            sources += rule.blockRegex ?? []
            if let inline = rule.blockJsInline { sources.append(inline) }
        }
        for blocker in SiteUnlockRules.generalBlockers
        where !blocker.excludedDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            sources.append(blocker.blockRegex)
        }
        // One pass: per-source results feed both the filter list and the
        // dropped count (re-running the expansion per source doubled the work).
        let perSource = sources.map(urlFilters(fromJSRegexSource:))
        let filters = perSource.flatMap { $0 }
        let dropped = perSource.filter(\.isEmpty).count
        if dropped > 0 {
            SharedDiagnosticLog.record(
                "unlock: dropped \(dropped)/\(sources.count) unrepresentable block patterns for \(host)",
                category: "archive")
        }
        let rules = filters.map { filter -> String in
            "{\"trigger\":{\"url-filter\":\"\(jsonEscaped(filter))\",\"resource-type\":\(blockResourceTypes)},"
            + "\"action\":{\"type\":\"block\"}}"
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    /// JSON-string-escape a regex (backslashes and quotes) for embedding in the rule.
    private static func jsonEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Compiles (and caches) the per-host content rule list. Calls back on the main
    /// thread with the list, or nil when there's nothing to block or compilation fails
    /// (in which case the reader proceeds with the DOM-cleanup userscript alone).
    public static func compiledRuleList(for url: URL, _ completion: @escaping (WKContentRuleList?) -> Void) {
        let json = contentRuleListJSON(for: url)
        guard json != "[]" else { completion(nil); return }
        let identifier = "luna-unlock-" + (url.host?.lowercased() ?? "site")
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: json
        ) { list, error in
            if let error {
                SharedDiagnosticLog.record(
                    "unlock rules compile error for \(identifier): \(error.localizedDescription)",
                    category: "archive")
            }
            DispatchQueue.main.async { completion(list) }
        }
    }

    // MARK: - DOM cleanup userscript

    /// Injected at documentStart; re-runs on an interval (covering the reader's poll
    /// window) to strip paywall overlays, unhide the article, restore scroll, and
    /// reveal AMP subscriber sections. NEVER runs on the archive.today reader.
    public static let domCleanupScript = """
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
        function ampUnhide() {
          document.querySelectorAll('[subscriptions-section="content-not-granted"]')
            .forEach(function (el) { el.remove(); });
          document.querySelectorAll('[subscriptions-section="content"]')
            .forEach(function (el) { el.removeAttribute('subscriptions-section'); });
          document.querySelectorAll('[amp-access][amp-access-hide]').forEach(function (el) {
            if (!/error|message/i.test(el.getAttribute('amp-access') || '')) {
              el.removeAttribute('amp-access-hide');
            }
          });
        }
        // Substantial article prose inside an element (>= 2 paragraphs over 60
        // chars); 0 when it holds none. Distinguishes a content wrapper from an
        // overlay/promo that happens to share a paywall class.
        function articleChars(el) {
          var ps = el.querySelectorAll('p'), c = 0, n = 0;
          for (var i = 0; i < ps.length; i++) {
            var t = (ps[i].textContent || '').trim().length;
            if (t > 60) { n++; c += t; }
          }
          return n >= 2 ? c : 0;
        }
        // Un-hide an element in place (used instead of removing a content wrapper).
        function reveal(el) {
          el.style.removeProperty('display');
          el.style.visibility = 'visible'; el.style.opacity = '1';
          el.style.maxHeight = 'none'; el.style.height = 'auto';
          el.style.overflow = 'visible'; el.style.filter = 'none'; el.style.webkitMaskImage = 'none';
          UNHIDE.forEach(function (c) { if (el.classList) { el.classList.remove(c); } });
        }
        function clean() {
          try {
            REMOVE.forEach(function (sel) {
              document.querySelectorAll(sel).forEach(function (el) {
                // Some sites deliver the UNLOCKED article inside the same node the
                // paywall class names (e.g. a `.paywall` content container). Deleting
                // it would take the story with it, leaving a de-walled teaser and no
                // body — so reveal a node that holds real prose, and only remove one
                // that's a genuine (content-less) overlay.
                if (articleChars(el) > 400) { reveal(el); } else { el.remove(); }
              });
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
            ampUnhide();
          } catch (e) {}
        }
        clean();
        var n = 0;
        var t = setInterval(function () { clean(); if (++n > 20) { clearInterval(t); } }, 700);
        document.addEventListener('DOMContentLoaded', clean);
      } catch (e) {}
    })();
    """

    public static func cleanupUserScript() -> WKUserScript {
        WKUserScript(source: domCleanupScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}
