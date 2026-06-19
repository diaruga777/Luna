// Tracks the active tab's URL and forwards it to the native handler (for the
// SaveLink intent), brokers the "Read in Queue" archive flow, and injects the
// content script on paywall/archive hosts.
//
// We inject programmatically with the scripting API (rather than a declarative
// `content_scripts` manifest block) — the minimal manifest keeps App Store
// validation happy, and the background page is already woken by tabs.onUpdated.

let lastSent = null;

// tabId -> original article URL, for tabs we redirected to archive.today via the
// "Read in Queue" button. Only these tabs auto-save their archive page; an
// arbitrary archive.is visit is never harvested.
const queueRedirects = {};

const PAYWALL_HOSTS = [
    "wsj.com", "ft.com", "nytimes.com", "economist.com", "bloomberg.com",
    "washingtonpost.com", "newyorker.com", "theatlantic.com", "wired.com",
    "barrons.com", "businessinsider.com", "theinformation.com", "hbr.org",
    "foreignpolicy.com", "foreignaffairs.com", "thetimes.co.uk", "telegraph.co.uk",
    "nikkei.com", "seekingalpha.com", "latimes.com", "bostonglobe.com"
];
const ARCHIVE_HOSTS = [
    "archive.is", "archive.ph", "archive.md", "archive.today",
    "archive.li", "archive.vn", "archive.fo"
];

function hostInList(hostname, list) {
    const h = (hostname || "").replace(/^www\./, "").toLowerCase();
    return list.some(function (d) { return h === d || h.endsWith("." + d); });
}

function report(url) {
    if (!url || !url.startsWith("http")) { return; }
    if (url === lastSent) { return; }
    lastSent = url;
    browser.runtime.sendNativeMessage("application.id", { url: url }, function (response) {
        void response;
    });
}

// Injects the Queue content script into a paywall/archive page once it loads.
function maybeInjectContentScript(tabId, url) {
    let host;
    try { host = new URL(url).hostname; } catch (e) { return; }
    if (!hostInList(host, PAYWALL_HOSTS) && !hostInList(host, ARCHIVE_HOSTS)) { return; }
    if (!browser.scripting || !browser.scripting.executeScript) { return; }
    browser.scripting.executeScript({
        target: { tabId: tabId },
        files: ["content.js"]
    }).catch(function () { /* page may block injection; ignore */ });
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
        maybeInjectContentScript(tabId, tab.url);
    }
});

// Drop a tab's redirect marker if it closes before harvesting.
browser.tabs.onRemoved.addListener(function (tabId) { delete queueRedirects[tabId]; });

browser.runtime.onMessage.addListener(function (message, sender) {
    if (!message || !message.type) { return; }
    const tabId = sender && sender.tab ? sender.tab.id : null;

    // The button was tapped: remember this tab, then send it to the snapshot.
    if (message.type === "queueRedirect" && tabId != null && message.url) {
        queueRedirects[tabId] = message.url;
        browser.tabs.update(tabId, { url: "https://archive.is/newest/" + message.url });
        return;
    }

    // The archive content script asks whether THIS tab is one of our redirects.
    if (message.type === "isQueueRedirect") {
        const original = tabId != null ? queueRedirects[tabId] : null;
        return Promise.resolve({ redirect: !!original, originalURL: original || null });
    }

    // The archive article was harvested: relay it to the native app (one-shot).
    if (message.type === "archiveContent" && tabId != null) {
        delete queueRedirects[tabId];
        return browser.runtime.sendNativeMessage("application.id", message);
    }
});

reportActiveTab();
