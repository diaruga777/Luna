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
    // news_hosts.generated.js / platform_hosts.generated.js define
    // self.__LUNA_NEWS_HOSTS / self.__LUNA_PLATFORM_HOSTS (the app's shared
    // NewsSites / PlatformRecognizer host lists) FIRST, in the same injected world,
    // so content.js's isKnownArticleHost/isKnownHardPaywallHost/recognizedPlatformPage
    // see them as soon as they run.
    browser.scripting.executeScript({
        target: { tabId: tabId },
        files: ["news_hosts.generated.js", "platform_hosts.generated.js", "content.js"]
    }).catch(function () { /* some pages block injection; ignore */ });
}

// --- Safari-onboarding takeover overlay --------------------------------------
// Asked once at script load ("onboardingStatus"): the native handler
// (SharedOnboardingStatus / SafariWebExtensionHandler) records that THIS
// extension is enabled and — if the app left a one-shot takeover pending for its
// Safari onboarding step — tells us to show a full-page "You're all set!"
// overlay with a real, user-tappable "Back to Luna" link. Never auto-navigates:
// that would fight the user's own navigation / could be blocked as a redirect.
let pendingTakeoverScheme = null;

// Runs INSIDE the page via scripting.executeScript — must be self-contained
// (no closures over background-page state). Mirrors content.js's toast styling
// (indigo #5856D6) for visual continuity with "Unlocked with Luna".
function lunaTakeoverOverlayScript(scheme) {
    if (document.getElementById("luna-onboarding-takeover")) { return; }
    var INDIGO = "#5856D6";
    var overlay = document.createElement("div");
    overlay.id = "luna-onboarding-takeover";
    overlay.style.cssText = "position:fixed;inset:0;z-index:2147483647;" +
        "background:" + INDIGO + ";color:#ffffff;" +
        "display:flex;flex-direction:column;align-items:center;justify-content:center;" +
        "text-align:center;padding:32px;box-sizing:border-box;" +
        "font-family:-apple-system,system-ui,sans-serif;";

    var headline = document.createElement("div");
    headline.textContent = "You're all set!";
    headline.style.cssText = "font-size:28px;font-weight:700;margin:0 0 12px;";

    var subline = document.createElement("div");
    subline.textContent = "The Luna extension is enabled.";
    subline.style.cssText = "font-size:17px;opacity:0.9;margin:0 0 32px;";

    var link = document.createElement("a");
    link.href = scheme + "://";
    link.textContent = "Back to Luna";
    link.style.cssText = "display:inline-block;background:#ffffff;color:" + INDIGO + ";" +
        "font-size:17px;font-weight:600;padding:14px 28px;border-radius:999px;" +
        "text-decoration:none;";

    overlay.appendChild(headline);
    overlay.appendChild(subline);
    overlay.appendChild(link);
    (document.body || document.documentElement).appendChild(overlay);
}

function injectTakeoverOverlay(scheme) {
    if (!browser.scripting || !browser.scripting.executeScript) { return; }
    browser.tabs.query({ active: true, currentWindow: true }).then(function (tabs) {
        var tab = tabs && tabs[0];
        if (!tab || !tab.id || !/^https?:\/\//i.test(tab.url || "")) {
            pendingTakeoverScheme = scheme; // no eligible tab yet — retry once
            return;
        }
        browser.scripting.executeScript({
            target: { tabId: tab.id }, func: lunaTakeoverOverlayScript, args: [scheme]
        }).catch(function () {
            pendingTakeoverScheme = scheme; // injection failed — retry once
        });
    }).catch(function () {
        pendingTakeoverScheme = scheme;
    });
}

function checkOnboardingStatus() {
    browser.runtime.sendNativeMessage("application.id", { type: "onboardingStatus" })
        .then(function (resp) {
            if (resp && resp.takeover && resp.scheme) {
                injectTakeoverOverlay(resp.scheme);
            }
        })
        .catch(function () {});
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
    // One retry for a takeover overlay that had no eligible tab the first time.
    if (pendingTakeoverScheme && changeInfo.status === "complete" && /^https?:\/\//i.test(tab.url || "")) {
        var scheme = pendingTakeoverScheme;
        pendingTakeoverScheme = null;
        injectTakeoverOverlay(scheme);
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
                    isDownloaderHost: !!(resp && resp.isDownloaderHost),
                    readerInstalled: !!(resp && resp.readerInstalled),
                    downloaderInstalled: !!(resp && resp.downloaderInstalled),
                    priceTrackerInstalled: !!(resp && resp.priceTrackerInstalled),
                    readerAppClipURL: (resp && resp.readerAppClipURL) || "",
                    downloaderAppClipURL: (resp && resp.downloaderAppClipURL) || "",
                    priceTrackerAppStoreURL: (resp && resp.priceTrackerAppStoreURL) || ""
                };
            })
            .catch(function () {
                return {
                    mode: "all",
                    isDownloaderHost: false,
                    readerInstalled: false,
                    downloaderInstalled: false,
                    priceTrackerInstalled: false,
                    readerAppClipURL: "",
                    downloaderAppClipURL: "",
                    priceTrackerAppStoreURL: ""
                };
            });
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
checkOnboardingStatus();
