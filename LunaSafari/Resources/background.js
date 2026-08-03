// Tracks the active tab's URL (for the SaveLink intent), injects the content
// script on web pages, and relays the Luna button settings/destinations from
// the native app to the content script.
//
// The article path deep-links into the Reader app (lunareader://read?url=…), where
// Luna does all archive.today / paywall handling in-app. Platform pages route to
// the Downloader app/clip (lunadownloader://), product pages to Price Tracker
// (lunapricetracker://), so the extension itself never touches archive.today.

let lastSent = null;

// Keep the paywall-bypass rulesets in sync with the app's "Unlock Paywalls" toggle
// (read from the shared App Group via the native handler). When on:
//   - "referer" rewrites the referrer the rule-listed hosts unlock for (WSJ/MarketWatch
//     → Drudge, FT/Investors Chronicle → Google);
//   - "blockers" blocks the metering/paywall vendor scripts (Piano.io, Poool, tinypass,
//     …) for the site that lists them — the browser mirror of the app's directUnlock
//     content-blocker, so a client-side wall (e.g. New Statesman) renders its full
//     article IN SAFARI, no app launch. Generated from the app's site_unlock_rules.json
//     by scripts/generate_safari_blocker_rules.js.
var BYPASS_RULESETS = ["referer", "blockers"];
function syncBypassRuleset() {
    if (!browser.declarativeNetRequest || !browser.declarativeNetRequest.updateEnabledRulesets) { return; }
    browser.runtime.sendNativeMessage("application.id", { type: "bypassEnabled" })
        .then(function (resp) {
            const on = !!(resp && resp.enabled);
            browser.declarativeNetRequest.updateEnabledRulesets(
                on ? { enableRulesetIds: BYPASS_RULESETS } : { disableRulesetIds: BYPASS_RULESETS }
            ).catch(function () {});
        })
        .catch(function () {});
}

function report(url) {
    if (!url || !url.startsWith("http")) { return; }
    if (url === lastSent) { return; }
    lastSent = url;
    browser.runtime.sendNativeMessage("application.id", { url: url }, function (response) {
        void response;
    });
}

function injectContentScript(tabId, url) {
    if (!/^https?:\/\//i.test(url || "")) { return; }
    if (!browser.scripting || !browser.scripting.executeScript) { return; }
    // Generated files define the app's shared news/platform/product classification
    // data FIRST, in the same injected world, so content.js sees the exact compiled
    // Swift rule values as soon as it runs.
    browser.scripting.executeScript({
        target: { tabId: tabId },
        files: ["news_hosts.generated.js", "platform_hosts.generated.js",
            "product_rules.generated.js", "content.js"]
    }).catch(function () { /* some pages block injection; ignore */ });
}

async function reportActiveTab() {
    try {
        const tabs = await browser.tabs.query({ active: true, currentWindow: true });
        if (tabs && tabs[0] && tabs[0].url) {
            report(tabs[0].url);
        }
    } catch (e) {
        // tabs may be unavailable briefly during startup; ignore.
    }
}

browser.tabs.onActivated.addListener(reportActiveTab);
browser.tabs.onActivated.addListener(syncBypassRuleset);

browser.tabs.onUpdated.addListener(function (tabId, changeInfo, tab) {
    if (!tab || !tab.active) { return; }
    if (changeInfo.url || changeInfo.status === "complete") {
        report(tab.url);
    }
    if (changeInfo.status === "complete" && tab.url) {
        injectContentScript(tabId, tab.url);
    }
});

browser.runtime.onMessage.addListener(function (message) {
    if (!message) { return; }
    // Content scripts can't call sendNativeMessage directly — relay for them.
    if (message.type === "buttonContext" || message.type === "buttonMode") {
        return browser.runtime.sendNativeMessage("application.id", { type: "buttonContext" })
            .then(function (resp) {
                return {
                    mode: (resp && resp.mode) || "all",
                    scheme: (resp && resp.scheme) || "",
                    supportsArticles: !!(resp && resp.supportsArticles),
                    supportsMedia: !!(resp && resp.supportsMedia),
                    supportsProducts: !!(resp && resp.supportsProducts),
                    celebrateSetup: !!(resp && resp.celebrateSetup),
                    appName: (resp && resp.appName) || ""
                };
            })
            .catch(function () {
                return {
                    mode: "all",
                    scheme: "",
                    supportsArticles: false,
                    supportsMedia: false,
                    supportsProducts: false,
                    celebrateSetup: false,
                    appName: ""
                };
            });
    }
    if (message.type === "setupCelebrationShown") {
        return browser.runtime.sendNativeMessage("application.id", { type: "setupCelebrationShown" })
            .then(function () { return { ok: true }; })
            .catch(function () { return { ok: false }; });
    }
    if (message.type === "bypassEnabled") {
        return browser.runtime.sendNativeMessage("application.id", { type: "bypassEnabled" })
            .then(function (resp) { return { enabled: !!(resp && resp.enabled) }; })
            .catch(function () { return { enabled: false }; });
    }
    if (message.type === "saveContent") {
        return browser.runtime.sendNativeMessage("application.id",
            { type: "saveContent", url: message.url, html: message.html })
            .then(function () { return { ok: true }; })
            .catch(function () { return { ok: false }; });
    }
});

syncBypassRuleset();
reportActiveTab();
