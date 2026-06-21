// Safari action-extension preprocessing: hands the current page's URL and
// title to the extension. Without this, a `com.apple.ui-services` action
// extension receives no usable web URL from Safari and appears to do nothing.
var GetURL = function() {};
GetURL.prototype = {
    run: function(parameters) {
        // Classify from cheap URL/DOM signals before deciding what to hand to the
        // extension. Platform links need no text extraction; product and paywall
        // candidates keep the normal fetch/price/archive routes. Only a substantial
        // text article supplies Safari's already-rendered text for immediate capture.
        var host = (window.location.hostname || "").toLowerCase();
        var platformHosts = ["youtube.com", "youtu.be", "tiktok.com", "instagram.com",
                             "instagr.am", "x.com", "twitter.com", "facebook.com", "fb.watch"];
        var isPlatform = false;
        for (var i = 0; i < platformHosts.length; i++) {
            var candidate = platformHosts[i];
            if (host === candidate || host.slice(-(candidate.length + 1)) === "." + candidate) {
                isPlatform = true;
                break;
            }
        }

        var knownProductHost = /(^|\.)(amazon\.(com|com\.au|co\.uk|ca|de|fr|it|es|co\.jp|in|com\.br|com\.mx|nl|se|sg)|target\.com|walmart\.com|ebay\.(com|co\.uk|com\.au|de)|etsy\.com|bunnings\.com\.au)$/.test(host);
        var hasProductMarkup = document.querySelector("meta[property='og:type'][content='product'], [itemtype='https://schema.org/Product'], [itemtype='http://schema.org/Product']") !== null;
        var declaresLocked = false;
        var jsonLDScripts = document.querySelectorAll("script[type='application/ld+json']");
        for (var scriptIndex = 0; scriptIndex < jsonLDScripts.length; scriptIndex++) {
            var scriptText = (jsonLDScripts[scriptIndex].textContent || "").toLowerCase();
            hasProductMarkup = hasProductMarkup || scriptText.indexOf("\"@type\":\"product\"") !== -1
                || scriptText.indexOf("\"@type\": \"product\"") !== -1;
            declaresLocked = declaresLocked || scriptText.indexOf("isaccessibleforfree\":false") !== -1;
        }

        if (isPlatform || knownProductHost || hasProductMarkup) {
            parameters.completionFunction({
                "URL": document.URL,
                "title": document.title,
                "Kind": isPlatform ? "platform" : "product",
                "ArticleText": null
            });
            return;
        }

        var textRoot = document.querySelector("article, main, [role='main']") || document.body;
        var text = textRoot ? (textRoot.innerText || "").trim() : "";
        var loweredText = text.toLowerCase();
        var hasBuyBox = loweredText.indexOf("add to cart") !== -1
            && /[$€£¥]\s*\d/.test(text);

        var knownPaywallHost = /(^|\.)(wsj\.com|ft\.com|nytimes\.com|economist\.com|bloomberg\.com|washingtonpost\.com|theatlantic\.com|newyorker\.com)$/.test(host);
        var isPaywalled = knownPaywallHost
            || declaresLocked
            || loweredText.indexOf("subscribe to continue reading") !== -1
            || loweredText.indexOf("subscribe to read this article") !== -1
            || loweredText.indexOf("already a subscriber") !== -1;

        var kind = hasBuyBox ? "product" : isPaywalled ? "paywall" : "unknown";
        var articleText = null;
        if (kind === "unknown" && text.length >= 600) {
            kind = "article";
            // Transport is bounded for extension IPC safety. This limit never decides
            // the page kind; it only limits how much already-classified article text
            // crosses the extension boundary.
            articleText = text.slice(0, 262144);
        }
        parameters.completionFunction({
            "URL": document.URL,
            "title": document.title,
            "Kind": kind,
            "ArticleText": articleText
        });
    },
    finalize: function(parameters) {}
};
var ExtensionPreprocessingJS = new GetURL;
