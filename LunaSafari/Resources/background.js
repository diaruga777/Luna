// Tracks the active tab's URL (for the SaveLink intent), injects the content
// script on web pages, and relays the Luna button settings/destinations from
// the native app to the content script.
//
// The article path deep-links into the Luna app (lunareader://read?url=…), where
// Luna does all archive.today / paywall handling in-app. Platform pages route to
// the Downloader app/clip, so the extension itself never touches archive.today.

let lastSent = null;

// Keep the Referer-rewrite ruleset in sync with the app's "Unlock Paywalls" toggle
// (read from the shared App Group via the native handler). When on, requests to the
// rule-listed hosts (WSJ/MarketWatch → Drudge, FT/Investors Chronicle → Google) get
// the referrer those sites unlock for — applied automatically in Safari, no app launch.
function syncBypassRuleset() {
    if (!browser.declarativeNetRequest || !browser.declarativeNetRequest.updateEnabledRulesets) { return; }
    browser.runtime.sendNativeMessage("application.id", { type: "bypassEnabled" })
        .then(function (resp) {
            const on = !!(resp && resp.enabled);
            browser.declarativeNetRequest.updateEnabledRulesets(
                on ? { enableRulesetIds: ["referer"] } : { disableRulesetIds: ["referer"] }
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
    browser.scripting.executeScript({ target: { tabId: tabId }, files: ["content.js"] })
        .catch(function () { /* some pages block injection; ignore */ });
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
                    isDownloaderHost: !!(resp && resp.isDownloaderHost),
                    readerAppClipURL: (resp && resp.readerAppClipURL) || "",
                    downloaderAppClipURL: (resp && resp.downloaderAppClipURL) || ""
                };
            })
            .catch(function () {
                return {
                    mode: "all",
                    isDownloaderHost: false,
                    readerAppClipURL: "",
                    downloaderAppClipURL: ""
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
