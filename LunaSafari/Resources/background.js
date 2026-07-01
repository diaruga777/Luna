// Tracks the active tab's URL (for the SaveLink intent), injects the content
// script on web pages, and relays the "Read in Luna" button-visibility setting
// from the native app to the content script.
//
// The content script only deep-links into the Luna app (lunareader://read?url=…)
// — Luna does all the archive.today / paywall handling in-app — so the extension
// itself no longer touches archive.today.

let lastSent = null;

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
    if (!message || message.type !== "buttonMode") { return; }
    // Content script asks when to show its button → fetch the app's setting.
    return browser.runtime.sendNativeMessage("application.id", { type: "buttonMode" })
        .then(function (resp) { return { mode: (resp && resp.mode) || "all" }; })
        .catch(function () { return { mode: "all" }; });
});

reportActiveTab();
