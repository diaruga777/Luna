#!/usr/bin/env node
// Generates the Safari extension's paywall-vendor-script BLOCK ruleset
// (LunaSafari/Resources/rules_blockers.json, declarativeNetRequest format) from the
// SAME LunaPaywallBypass/Resources/site_unlock_rules.json the in-app WKWebView
// content-blocker uses (PaywallUnlockRules.contentRuleListJSON). This is what lets
// Safari unlock a client-side wall (e.g. New Statesman's Piano.io scripts) IN PLACE,
// with no app launch — the browser mirror of the app's directUnlock content-blocker.
//
// Each site rule's `blockRegex` becomes a declarativeNetRequest `block` rule scoped
// to that site's `requestDomains`; each global `generalBlockers` entry becomes an
// unscoped block rule carrying its `excludedRequestDomains`. Only `script`/`xhr`
// requests are blocked (mirrors the app's ["script","raw"] resource types), so a
// blocked meter script can never take a main-frame navigation with it.
//
// Regenerate after editing site_unlock_rules.json:
//   node scripts/generate_safari_blocker_rules.js

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const SRC = path.join(
    ROOT, "LunaLibraries/Sources/LunaPaywallBypass/Resources/site_unlock_rules.json");
const OUT = path.join(ROOT, "LunaSafari/Resources/rules_blockers.json");

const RESOURCE_TYPES = ["script", "xmlhttprequest"];

// RE2 (declarativeNetRequest's engine) rejects lookaround and backreferences, and an
// invalid rule fails the WHOLE ruleset to load — so drop any pattern using them.
function isRE2Safe(pattern) {
    if (/\(\?[=!<]/.test(pattern)) { return false; }   // lookahead/lookbehind
    if (/\\[1-9]/.test(pattern)) { return false; }      // backreference
    return true;
}

// A pattern with no regex metacharacters (only literals and the escapes `\.`/`\/`/`\-`)
// is a plain substring match — e.g. `\.piano\.io\/`. declarativeNetRequest's `urlFilter`
// expresses that directly (its only specials are `* | ^`, everything else is literal),
// and urlFilter rules do NOT count against Safari's much smaller `regexFilter` cap — so
// converting the common vendor-domain blocks keeps the ruleset well under that limit and
// only genuinely complex patterns stay as regex. Returns the urlFilter, or null.
function asUrlFilter(pattern) {
    const unescaped = pattern.replace(/\\([./-])/g, "$1");
    // After unescaping, a simple pattern is only host/path characters. Anything with a
    // regex metachar (`* + ? ( ) [ ] { } | ^ $ \`) must stay a regexFilter.
    if (/[*+?()\[\]{}|^$\\]/.test(unescaped)) { return null; }
    // urlFilter treats `*` as a wildcard; our simple patterns contain none, so the
    // literal string is matched as a substring anywhere in the URL — exactly the
    // semantics of the original `\.vendor\.tld\/` regex.
    return unescaped;
}

const data = JSON.parse(fs.readFileSync(SRC, "utf8"));
const rules = [];
let id = 1;

let regexCount = 0;

function pushRule(pattern, condition) {
    const urlFilter = asUrlFilter(pattern);
    let match;
    if (urlFilter) {
        match = { urlFilter };
    } else {
        if (!isRE2Safe(pattern)) { return; }
        match = { regexFilter: pattern };
        regexCount++;
    }
    rules.push({
        id: id++,
        priority: 1,
        action: { type: "block" },
        condition: Object.assign(match, { resourceTypes: RESOURCE_TYPES }, condition),
    });
}

// Per-site vendor-script blocks, scoped to the PAGE's domain. This is
// `initiatorDomains` (the document making the request), NOT `requestDomains`: the
// vendor script is served from a THIRD party (New Statesman's Piano loads from
// piano.io), so scoping by the request's own domain would never match — we want
// "block piano.io requests made BY a newstatesman.com page". `initiatorDomains`
// matches the domain and its subdomains (so www.newstatesman.com is covered).
let skippedUARules = 0;
for (const rule of data.rules || []) {
    if (!rule.domain || !Array.isArray(rule.blockRegex)) { continue; }
    // A site whose in-app unlock depends on a spoofed request User-Agent
    // (`useragentCustom` — e.g. nytimes.com / economist.com serve the full article to
    // Google's crawler UA) CANNOT be unlocked the same way in Safari: the extension has
    // no per-site request-UA control (declarativeNetRequest can't do it, and content
    // scripts run after the request). Emitting only the script BLOCKS for such a site
    // does not unlock it — worse, it blocks the site's own entitlement/messaging XHR
    // without the UA that makes that safe, so the SPA gets a failed fetch and blanks
    // after its server-rendered content briefly shows (the NYT "renders then goes
    // blank" bug). Skip these entirely; the pill -> in-app reader still unlocks them
    // (the in-app WKWebView CAN set the crawler UA). This keys on the rule shape, not a
    // site name — any UA-dependent rule is excluded.
    if (rule.useragentCustom) { skippedUARules++; continue; }
    for (const pattern of rule.blockRegex) {
        pushRule(pattern, { initiatorDomains: [rule.domain] });
    }
}

// Global vendor blockers, applied on every page except their opt-outs (again scoped
// by the initiating page, mirroring the app's WKContentRuleList `unless-domain`).
for (const blocker of data.generalBlockers || []) {
    if (!blocker.blockRegex) { continue; }
    const condition = {};
    if (Array.isArray(blocker.excludedDomains) && blocker.excludedDomains.length) {
        condition.excludedInitiatorDomains = blocker.excludedDomains;
    }
    pushRule(blocker.blockRegex, condition);
}

fs.writeFileSync(OUT, JSON.stringify(rules, null, 0) + "\n");
console.log(`wrote ${rules.length} block rules (${regexCount} regexFilter, `
    + `${rules.length - regexCount} urlFilter) to ${path.relative(ROOT, OUT)}`);
console.log(`skipped ${skippedUARules} UA-spoof-dependent site rule(s) `
    + `(not safely reproducible in Safari; handled by the in-app reader)`);
