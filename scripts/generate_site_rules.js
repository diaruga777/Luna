#!/usr/bin/env node
//
// generate_site_rules.js — convert an upstream paywall-unlock rule source (a
// browser-extension `sites.js` config file) into the normalized
// site_unlock_rules.json that Luna bundles (LunaPaywallBypass/Resources).
//
// The source is a browser-extension script: a big `defaultSites` object of per-site
// configs, then a Chromium/Firefox tail that patches a couple of sites and builds
// grouped_sites. We eval the whole file in a VM with chrome/browser stubbed
// (Chromium variant), then flatten:
//   - group configs (domain "###_x" + group:[...]) → one rule per member domain
//   - exception:[{domain,...}] → per-member overrides merged onto the base
//   - {domain} placeholders in block_regex/block_js_inline → substituted per domain
//   - RegExp literals → their .source string (JSON can't hold regexes)
//   - block_regex_general entries → a separate generalBlockers[] (apply to all sites)
//   - nofix_sites → noFix[] (known-unsupported denylist)
//
// Usage: node scripts/generate_site_rules.js <path/to/source/sites.js> [out.json]
// Re-run whenever the upstream rules update. Deterministic (no Date/random).

const fs = require("fs");
const vm = require("vm");

const SRC = process.argv[2];
if (!SRC) {
    console.error("usage: node scripts/generate_site_rules.js <path/to/sites.js> [out.json]");
    process.exit(1);
}
const OUT = process.argv[3]
    || "LunaLibraries/Sources/LunaPaywallBypass/Resources/site_unlock_rules.json";

const code = fs.readFileSync(SRC, "utf8");
const sandbox = { console };
// Chromium variant so the tail's NY Post / Jeune Afrique patches apply.
sandbox.chrome = { runtime: { getManifest: () => ({ key: "chromium" }) } };
sandbox.browser = sandbox.chrome;
vm.createContext(sandbox);
vm.runInContext(code, sandbox, { filename: "sites.js" });

const defaultSites = sandbox.defaultSites;
if (!defaultSites) { throw new Error("defaultSites not found — sites.js layout changed"); }
const noFix = sandbox.nofix_sites || [];

// Regexes created inside the VM aren't `instanceof` the host RegExp (different
// realm), so detect via the cross-realm brand and return the delimiter-free source.
const isRegex = (v) => Object.prototype.toString.call(v) === "[object RegExp]";
const reSrc = (v) => (isRegex(v) ? v.source : (typeof v === "string" ? v : String(v)));

// The technique fields we port (camelCased). Absent keys stay absent.
function techniques(rule) {
    const t = {};
    if (rule.allow_cookies) { t.allowCookies = true; }
    if (rule.block_regex) {
        const arr = Array.isArray(rule.block_regex) ? rule.block_regex : [rule.block_regex];
        t.blockRegex = arr.map(reSrc);
    }
    if (rule.block_js_inline) { t.blockJsInline = reSrc(rule.block_js_inline); }
    if (rule.useragent) { t.useragent = rule.useragent; }
    if (rule.useragent_custom) { t.useragentCustom = rule.useragent_custom; }
    if (rule.referer) { t.referer = rule.referer; }
    if (rule.referer_custom) { t.refererCustom = rule.referer_custom; }
    if (rule.headers_custom) { t.headersCustom = rule.headers_custom; }
    if (rule.random_ip) { t.randomIP = String(rule.random_ip); }
    if (rule.remove_cookies) { t.removeCookies = true; }
    if (rule.remove_cookies_select_drop) { t.removeCookiesSelectDrop = rule.remove_cookies_select_drop; }
    if (rule.remove_cookies_select_hold) { t.removeCookiesSelectHold = rule.remove_cookies_select_hold; }
    if (rule.cs_clear_lclstrg) { t.clearLocalStorage = true; }
    if (rule.cs_dompurify) { t.csDompurify = true; }
    if (rule.ld_json) { t.ldJson = rule.ld_json; }
    if (rule.ld_json_next) { t.ldJsonNext = rule.ld_json_next; }
    if (rule.ld_json_source) { t.ldJsonSource = rule.ld_json_source; }
    if (rule.ld_json_url) { t.ldJsonUrl = rule.ld_json_url; }
    if (rule.cs_code) { t.csCode = rule.cs_code; }
    if (rule.amp_unhide) { t.ampUnhide = true; }
    if (rule.amp_redirect) { t.ampRedirect = reSrc(rule.amp_redirect); }
    return t;
}

// Substitute {domain} (the upstream group placeholder) in regex-source strings.
function substitute(t, domain) {
    const esc = domain.replace(/\./g, "\\.");
    const out = JSON.parse(JSON.stringify(t));
    if (out.blockRegex) {
        out.blockRegex = out.blockRegex.map((s) => String(s).replace(/\{domain\}/g, esc));
    }
    if (out.blockJsInline) { out.blockJsInline = String(out.blockJsInline).replace(/\{domain\}/g, esc); }
    return out;
}

const rules = [];
const generalBlockers = [];
const seen = new Set();

for (const name in defaultSites) {
    const rule = defaultSites[name];
    const domain = rule.domain;
    if (!domain || domain === "###" || domain.startsWith("#options")) { continue; }

    if (rule.block_regex_general) {
        generalBlockers.push({
            blockRegex: reSrc(rule.block_regex_general),
            excludedDomains: rule.excluded_domains || [],
        });
    }

    const domains = domain.startsWith("###_") ? (rule.group || []) : [domain];
    if (domains.length === 0) { continue; }   // empty opt-in group: no default members

    const base = techniques(rule);

    // Per-member exception overrides.
    const overrides = {};
    if (Array.isArray(rule.exception)) {
        for (const exc of rule.exception) {
            const ds = Array.isArray(exc.domain) ? exc.domain : [exc.domain];
            const merged = Object.assign({}, base, techniques(exc));
            for (const d of ds) { overrides[d] = merged; }
        }
    }

    for (const d of domains) {
        if (seen.has(d)) { continue; }   // first rule wins on duplicates
        seen.add(d);
        const t = overrides[d] || base;
        if (Object.keys(t).length === 0) { continue; }   // no portable technique
        rules.push(Object.assign({ domain: d }, substitute(t, d)));
    }
}

const output = {
    generatedFrom: "upstream paywall-unlock sites.js",
    ruleCount: rules.length,
    rules,
    generalBlockers,
    noFix,
};
fs.mkdirSync(require("path").dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(output, null, 1));
console.log(`rules=${rules.length} generalBlockers=${generalBlockers.length} noFix=${noFix.length} → ${OUT}`);
