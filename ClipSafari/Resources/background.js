// Tracks the active tab's URL and forwards it to the native handler (for the
// SaveLink intent), and brokers the "Read in Queue" archive flow for the content
// script (which can't talk to the native app directly).

let lastSent = null;

// tabId -> original article URL, for tabs we redirected to archive.today via the
// "Read in Queue" button. Only these tabs are allowed to auto-save their archive
// page; an arbitrary archive.is visit is never harvested.
const queueRedirects = {};

function report(url) {
    if (!url || !url.startsWith("http")) { return; }
    if (url === lastSent) { return; }
    lastSent = url;
    browser.runtime.sendNativeMessage("application.id", { url: url }, function (response) {
        void response;
    });
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
    if (tab && tab.active && (changeInfo.url || changeInfo.status === "complete")) {
        report(tab.url);
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
