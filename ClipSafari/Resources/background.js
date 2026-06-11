// Tracks the active tab's URL and forwards it to the native handler, which
// persists it in the App Group for the Clip app and SaveLink intent.

let lastSent = null;

function report(url) {
    if (!url || !url.startsWith("http")) { return; }
    if (url === lastSent) { return; }
    lastSent = url;
    browser.runtime.sendNativeMessage("application.id", { url: url }, function (response) {
        // Ack only; nothing to do. Reading the response avoids unhandled errors.
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

reportActiveTab();
