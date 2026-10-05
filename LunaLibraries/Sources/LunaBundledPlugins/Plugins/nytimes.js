/* luna-plugin
{
  "id": "app.luna.nytimes",
  "name": "New York Times",
  "version": "1.1.2",
  "api": 1,
  "description": "Reads New York Times articles through the trailing-dot hostname and plugin-owned article extraction.",
  "produces": ["article"],
  "match": {
    "hosts": ["nytimes.com", "*.nytimes.com", "nyt.com", "*.nyt.com"]
  },
  "priority": 100,
  "capabilities": ["fetch", "html"]
}
*/

// BEGIN BUNDLED WEB HELPER
// Plugin-owned web interpretation. Bundled into each opting-in plugin by
// scripts/bundle_plugin_helpers.py; never evaluated by the native host itself.
const LunaWeb = (function () {
    function escape(value) { return String(value || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }
    function absoluteURL(value, base) {
        if (!value) { return null; }
        const doc = luna.html.parse('<a href="' + escape(value) + '"></a>', base);
        const node = doc.querySelector('a');
        return node ? node.absoluteURL('href') : null;
    }
    function jsonLD(doc) {
        var out = [];
        luna.html.jsonScripts(doc, "application/ld+json").forEach(function (value) {
            if (Array.isArray(value)) {
                value.forEach(function (entry) { appendGraph(entry, out); });
                return;
            }
            appendGraph(value, out);
        });
        return out;
    }

    function appendGraph(value, out) {
        if (value && typeof value === "object" && Array.isArray(value["@graph"])) {
            value["@graph"].forEach(function (entry) { out.push(entry); });
            return;
        }
        out.push(value);
    }

    /// The JSON-LD `@type`s that answer for the document as a whole.
    var LD_DOCUMENT_TYPES = ["Article", "NewsArticle", "BlogPosting", "Product"];

    /// `luna.html.meta` — one page's own account of itself, read out of
    /// OpenGraph, Twitter cards, plain `<meta name>`, `<link rel=canonical>`,
    /// `<title>`, `<html lang>` and JSON-LD, in that order per key. The rules
    /// are `PluginHTMLMetadata.swift`'s, case for case.
    function htmlMeta(doc) {
        var linked = jsonLD(doc).filter(function (object) {
            if (!object || typeof object !== "object") { return false; }
            var raw = object["@type"];
            var names = typeof raw === "string" ? [raw] : (Array.isArray(raw) ? raw : []);
            return names.some(function (name) { return LD_DOCUMENT_TYPES.indexOf(name) >= 0; });
        });

        function attribute(selector, name) {
            var node = doc.querySelector(selector);
            if (!node) { return null; }
            return clean(node.getAttribute(name));
        }
        function property(name) {
            return attribute('meta[property="' + name + '"]', "content")
                || attribute('meta[name="' + name + '"]', "content");
        }
        function named(name) { return attribute('meta[name="' + name + '"]', "content"); }
        function linkedField(field) {
            for (var i = 0; i < linked.length; i++) {
                var value = clean(linked[i][field]);
                if (value) { return value; }
            }
            return null;
        }
        function linkedNamed(field) {
            for (var i = 0; i < linked.length; i++) {
                var value = linked[i][field];
                var found = namedValue(value);
                if (found) { return found; }
            }
            return null;
        }
        function namedValue(value) {
            if (typeof value === "string") { return clean(value); }
            if (Array.isArray(value)) {
                for (var i = 0; i < value.length; i++) {
                    var found = namedValue(value[i]);
                    if (found) { return found; }
                }
                return null;
            }
            if (value && typeof value === "object") { return clean(value.name); }
            return null;
        }
        function linkedImage() {
            for (var i = 0; i < linked.length; i++) {
                var value = linked[i].image;
                if (typeof value === "string") { return clean(value); }
                if (Array.isArray(value)) { value = value[0]; }
                if (typeof value === "string") { return clean(value); }
                if (value && typeof value === "object" && clean(value.url)) {
                    return clean(value.url);
                }
            }
            return null;
        }
        function absolute(value) {
            if (!value) { return null; }
            try { return absoluteURL(value, doc.baseURI); } catch (e) { return value; }
        }

        var found = {
            title: property("og:title") || property("twitter:title") || clean(doc.title)
                || linkedField("headline") || linkedField("name"),
            description: property("og:description") || property("twitter:description")
                || named("description"),
            canonical: absolute(property("og:url") || attribute('link[rel="canonical"]', "href")),
            image: absolute(property("og:image") || property("og:image:url")
                || property("twitter:image") || property("twitter:image:src") || linkedImage()),
            author: named("author") || property("article:author") || linkedNamed("author"),
            published: property("article:published_time") || named("date") || named("pubdate")
                || attribute('meta[itemprop="datePublished"]', "content")
                || attribute('[itemprop="datePublished"]', "datetime")
                || linkedField("datePublished"),
            siteName: property("og:site_name") || named("application-name"),
            language: clean(doc.documentElement && doc.documentElement.getAttribute("lang"))
                || attribute('meta[http-equiv="content-language"]', "content")
                || linkedField("inLanguage"),
            type: property("og:type"),
        };
        var result = {};
        Object.keys(found).forEach(function (key) {
            if (found[key]) { result[key] = found[key]; }
        });
        return result;
    }

    // -------------------------------------------------------------- luna.text

    /// The currency symbols `PriceParsing.normalizeCurrency` knows.
    var CURRENCY_SYMBOLS = { "$": "USD", "£": "GBP", "€": "EUR", "¥": "JPY" };

    var MONTHS = ["january", "february", "march", "april", "may", "june",
                  "july", "august", "september", "october", "november", "december"];

    /// Any run of Unicode whitespace becomes one space, and the result is
    /// trimmed. `\s` covers the no-break space, which is what a scraped label
    /// is usually padded with.
    function collapseWhitespace(text) {
        return String(text === undefined || text === null ? "" : text)
            .replace(/\s+/g, " ").trim();
    }

    /// Whitespace-collapsed, or null when nothing is left.
    function clean(value) {
        if (value === undefined || value === null) { return null; }
        var text = collapseWhitespace(value);
        return text === "" ? null : text;
    }

    /// `"$1,299.00"` -> `{amount:"1299.00",currency:"USD"}`. The separator rule
    /// is `PriceParsing`'s: with both separators present the later one is the
    /// decimal point; a lone comma is a decimal point only before one or two
    /// digits.
    function textPrice(raw) {
        var source = String(raw === undefined || raw === null ? "" : raw);
        var match = source.match(/[0-9][0-9.,]*/);
        if (!match) { return null; }
        var run = match[0].replace(/[.,]+$/, "");
        if (!run) { return null; }
        var lastDot = run.lastIndexOf(".");
        var lastComma = run.lastIndexOf(",");
        var amount;
        if (lastDot >= 0 && lastComma >= 0) {
            amount = lastDot > lastComma
                ? run.replace(/,/g, "")
                : run.replace(/\./g, "").replace(/,/g, ".");
        } else if (lastComma >= 0) {
            var afterComma = run.length - lastComma - 1;
            amount = (afterComma === 1 || afterComma === 2)
                ? run.replace(/,/g, ".")
                : run.replace(/,/g, "");
        } else {
            amount = run;
        }
        var start = source.indexOf(match[0]);
        var before = source.slice(0, start).replace(/\s+$/, "");
        var after = source.slice(start + run.length).replace(/^\s+/, "");
        var currency = null;
        Object.keys(CURRENCY_SYMBOLS).forEach(function (symbol) {
            if (currency) { return; }
            if (before.slice(-symbol.length) === symbol || after.slice(0, symbol.length) === symbol) {
                currency = CURRENCY_SYMBOLS[symbol];
            }
        });
        if (!currency) {
            var trailing = before.match(/([A-Za-z]+)$/);
            var leading = after.match(/^([A-Za-z]+)/);
            var code = (trailing && trailing[1]) || (leading && leading[1]) || "";
            if (code.length === 3 && code === code.toUpperCase()) { currency = code; }
        }
        var price = { amount: amount };
        if (currency) { price.currency = currency; }
        return price;
    }

    /// An absolute date as ISO 8601, or null. A date with a time answers UTC
    /// (`…T09:30:00Z`); a date without one answers `YYYY-MM-DD`, which is what
    /// the page said. A relative phrase answers null.
    function textDate(raw) {
        var text = String(raw === undefined || raw === null ? "" : raw).trim();
        if (!text) { return null; }
        var m = text.match(
            /^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|z|[+-]\d{2}:?\d{2})?)?$/);
        if (m) {
            return m[4] === undefined
                ? plainDate(+m[1], +m[2], +m[3])
                : instant(+m[1], +m[2], +m[3], +m[4], +m[5], +(m[6] || 0), m[7]);
        }
        m = text.match(/^(\d{4})\/(\d{1,2})\/(\d{1,2})$/);
        if (m) { return plainDate(+m[1], +m[2], +m[3]); }
        m = text.match(/^([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})$/);
        if (m && monthNumber(m[1])) { return plainDate(+m[3], monthNumber(m[1]), +m[2]); }
        m = text.match(/^(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9})\.?,?\s+(\d{4})$/);
        if (m && monthNumber(m[2])) { return plainDate(+m[3], monthNumber(m[2]), +m[1]); }
        m = text.match(
            /^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s*(GMT|UTC|Z|[+-]\d{4})?$/);
        if (m && monthNumber(m[2])) {
            return instant(+m[3], monthNumber(m[2]), +m[1], +m[4], +m[5], +(m[6] || 0), m[7]);
        }
        return null;
    }

    function monthNumber(name) {
        var lower = String(name).toLowerCase();
        for (var i = 0; i < MONTHS.length; i++) {
            if (MONTHS[i] === lower || (lower.length === 3 && MONTHS[i].indexOf(lower) === 0)) {
                return i + 1;
            }
        }
        return 0;
    }

    function isRealDay(year, month, day) {
        if (!(year >= 1000 && year <= 9999) || month < 1 || month > 12 || day < 1) { return false; }
        var leap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
        var lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        return day <= lengths[month - 1];
    }

    function pad(value, width) {
        var text = String(value);
        while (text.length < width) { text = "0" + text; }
        return text;
    }

    function plainDate(year, month, day) {
        if (!isRealDay(year, month, day)) { return null; }
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2);
    }

    function instant(year, month, day, hour, minute, second, zone) {
        if (!isRealDay(year, month, day) || hour > 23 || minute > 59 || second > 59) {
            return null;
        }
        var offset = 0;
        var m = String(zone || "").trim().match(/^([+-])(\d{2}):?(\d{2})$/);
        if (m) { offset = (m[1] === "-" ? -1 : 1) * ((+m[2]) * 3600 + (+m[3]) * 60); }
        var stamp = Date.UTC(year, month - 1, day, hour, minute, second) - offset * 1000;
        var moment = new Date(stamp);
        return pad(moment.getUTCFullYear(), 4) + "-" + pad(moment.getUTCMonth() + 1, 2) + "-"
            + pad(moment.getUTCDate(), 2) + "T" + pad(moment.getUTCHours(), 2) + ":"
            + pad(moment.getUTCMinutes(), 2) + ":" + pad(moment.getUTCSeconds(), 2) + "Z";
    }

    /// Entities decoded, tags dropped, whitespace collapsed, trimmed — the
    /// same rule `PluginTextParsing.clean` follows, over `luna.html.text`.
    function textClean(raw) {
        return collapseWhitespace(luna.html.text(String(raw === undefined || raw === null ? "" : raw)));
    }

    var text = { price: textPrice, isInterstitial: isInterstitial, date: textDate, clean: textClean };


    const gateMarkers = ["to continue reading", "continue reading this article", "continue reading with", "login or signup to continue", "log in or sign up to continue", "sign in to continue reading", "log in to continue reading", "subscribe to continue", "subscribe to read", "register to continue", "sign up to continue reading", "subscribe now for unlimited", "subscribe for unlimited access", "this article is for subscribers", "this story is for subscribers", "this content is for subscribers", "available to subscribers", "subscribers only", "subscriber exclusive", "to read the full article", "to read the full story", "for full access", "already a subscriber? log in", "already a subscriber? sign in", "unlock this article", "this article is reserved for subscribers"];
    const weakMarkers = ["try unlimited access", "unlimited digital access", "complete digital access", "digital access to quality", "cancel anytime", "subscriber agreement", "personal, non-commercial use", "sign in to read", "become a subscriber", "start your free trial", "supporter subscription", "subscribe now", "create a free account", "support local journalism", "your subscription"];
    const gateName = /paywall|pay-wall|regwall|reg-wall|registration-wall|subscribe-wall|subscription-wall|subscriber-wall|article-gate|content-gate|premium-gate|meter-gate|piano-gate/i;
    const noise = /(?:^|[\s_-])(comments?|related|recirc|recommend|newsletter|subscribe|advert|social|share|menu|nav|footer|cookie|promo|breadcrumb)(?:$|[\s_-])/i;
    const structural = new Set(['SCRIPT','STYLE','NAV','FOOTER','ASIDE','FORM','BUTTON','NOSCRIPT']);
    const blockTags = new Set(['P','H1','H2','H3','H4','H5','H6','LI','BLOCKQUOTE','FIGURE','IMG','PRE','TABLE']);
    const containerTags = new Set(['DIV','SECTION','ARTICLE','MAIN','UL','OL']);
    function isInterstitial(url) {
        const parsed=luna.parseURL(url);
        return !!parsed && parsed.pathname.toLowerCase().split('/').some(p =>
            ['subscribe','subscribes','subscription','subscriptions','paywall','signin','sign-in','login','log-in','register','checkout','check_cookie.html'].includes(p));
    }
    // Keep identity, ancestry and document order in JavaScript. Comparing outerHTML
    // loses repeated paragraphs and repeatedly serializes entire article subtrees.
    function articleTree(node, parent, entries) {
        const value={node,parent,index:entries.length,tag:node.tagName,children:[]};
        entries.push(value);
        value.label=(node.getAttribute('class')||'')+' '+(node.getAttribute('id')||'');
        value.hidden=node.hasAttribute('hidden') || node.getAttribute('aria-hidden')==='true'
            || /(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)/i.test(node.getAttribute('style')||'');
        value.marker=node.getAttribute('itemprop')==='articleBody' || /(?:^|\s)(article-body|entry-content|post-content)(?:\s|$)/.test(value.label);
        for(const child of node.children) value.children.push(articleTree(child,value,entries));
        value.text=node.textContent;
        value.prose=value.tag==='P' ? value.text.length : value.children.reduce((n,c)=>n+c.prose,0);
        value.skip=value.hidden || structural.has(value.tag) ||
            (!['HTML','BODY'].includes(value.tag) && noise.test(value.label)) ||
            (gateName.test(value.label) && value.prose<800);
        return value;
    }
    function inside(value,root) { for(let n=value;n;n=n.parent)if(n===root)return true;return false; }
    function visible(value,root) { for(let n=value;n;n=n.parent){if(n.skip)return false;if(n===root)break;}return true; }
    function truncation(entries) {
        const paragraphs=entries.filter(n=>n.tag==='P' && n.text.length>=40 && !n.hidden);
        for(const gate of entries.filter(n=>gateName.test(n.label) && !n.hidden && n.prose<800)) {
            const text=gate.text.toLowerCase();
            if(!gateMarkers.concat(['already a subscriber','sign in','subscribe']).some(m=>text.includes(m)))continue;
            for(let scope=gate.parent;scope;scope=scope.parent) {
                let before=0,after=0;
                for(const p of paragraphs)if(inside(p,scope)&&!inside(p,gate)){
                    if(p.index<gate.index)before+=p.text.length;else after+=p.text.length;
                }
                if(before>=1200){if(after<=before*.2)return true;break;}
            }
        }
        return false;
    }
    function article(source, base) {
        const parsedURL=luna.parseURL(base);
        if(isInterstitial(base) || (parsedURL && /\/(search|category|tag|topics|archive)(\/|$)/i.test(parsedURL.pathname)))return null;
        const doc=luna.html.parse(source,base), meta=htmlMeta(doc), entries=[];
        const root=doc.body && articleTree(doc.body,null,entries);
        if(!root)return null;
        const linked=jsonLD(doc).find(entry=>entry && /Article|BlogPosting/.test(String(entry['@type'])));
        // A publisher explicitly withholding the body is stronger than page length.
        if(doc.querySelector('script[data-component-name="Article"]') && luna.html.jsonScripts(doc,'application/json').some(v=>v && v.article && v.article.access==='locked' && v.article.fullText===null))return null;
        if(truncation(entries))return null;
        function length(n) {
            if(n.skip)return 0;
            if(n.tag==='P' || (['DIV','SECTION'].includes(n.tag) && !n.children.some(c=>containerTags.has(c.tag)||blockTags.has(c.tag))))return n.text.length;
            return n.children.reduce((sum,c)=>sum+length(c),0);
        }
        let candidates=entries.filter(n=>visible(n,root) && (n.tag==='ARTICLE'||n.marker));
        // Explicit body containers outrank unrelated discussion within an article.
        // Repeated leaf markers represent paragraphs, so use their common container.
        const bodies=candidates.filter(n=>n.marker && n.children.some(c=>containerTags.has(c.tag)||blockTags.has(c.tag)) && length(n)>=300);
        if(bodies.length)candidates=bodies;
        else {
            const articles=candidates.filter(n=>n.tag==='ARTICLE');
            if(articles.length)candidates=articles.filter(n=>!articles.some(other=>other!==n && inside(other,n) && length(other)>=300));
            else candidates=entries.filter(n=>visible(n,root) && (n.tag==='MAIN'||n.node.getAttribute('role')==='main'));
        }
        if(!candidates.length)candidates=[root];
        let winner=null,best=0;
        for(const n of candidates){
            const linkedLength=entries.filter(a=>a.tag==='A'&&inside(a,n)&&visible(a,n)).reduce((sum,a)=>sum+a.text.length,0);
            const score=length(n)-linkedLength*1.5;
            if(score>best){winner=n;best=score;}
        }
        const selected=[];
        function collect(n) {
            if(n.skip)return;
            if(blockTags.has(n.tag)) { selected.push(n);return; }
            if(['DIV','SECTION'].includes(n.tag) && !n.children.some(c=>containerTags.has(c.tag)||blockTags.has(c.tag)) && n.text.trim()) {
                selected.push(n);return;
            }
            n.children.forEach(collect);
        }
        if(winner && best>=300)collect(winner);
        let html=selected.map(n=>['DIV','SECTION'].includes(n.tag)?'<p>'+n.node.innerHTML+'</p>':n.node.outerHTML).join('\n');
        let body=selected.map(n=>n.text).join('\n').trim();
        if(linked && typeof linked.articleBody==='string' && linked.articleBody.length>2*body.length){
            body=linked.articleBody;
            html=body.split(/\n+/).filter(Boolean).map(p=>'<p>'+escape(p)+'</p>').join('');
        }
        if(body.length<300 || !html)return null;
        const lower=body.toLowerCase();
        const tier=doc.querySelector('meta[property="article:content_tier"],meta[name="article:content_tier"],meta[name="article:content-tier"]');
        const declaredLocked=(linked && [false,'false'].includes(linked.isAccessibleForFree)) || (tier && /locked|metered|premium/i.test(tier.getAttribute('content')||''));
        if(gateMarkers.some(m=>lower.includes(m)) || (body.length<2500 && (declaredLocked || weakMarkers.some(m=>lower.includes(m)))))return null;
        const heading=winner && winner.node.querySelector('h1');
        const result={title:meta.title || (heading && heading.textContent) || base,html,text:body};
        if(meta.author)result.author=meta.author;
        if(meta.image)result.leadImageURL=meta.image;
        if(meta.description)result.excerpt=meta.description.slice(0,1000);
        if(meta.published)result.publishedAt=textDate(meta.published)||undefined;
        return result;
    }
    return {article: article, meta: htmlMeta, jsonLD: jsonLD, price: textPrice,
        isInterstitial: isInterstitial, date: textDate, clean: textClean, escape: escape, absoluteURL: absoluteURL};
})();
// END BUNDLED WEB HELPER

function isNYTHost(host) {
    const normalized = String(host || "").toLowerCase().replace(/\.$/, "");
    return normalized === "nytimes.com" || normalized.endsWith(".nytimes.com")
        || normalized === "nyt.com" || normalized.endsWith(".nyt.com");
}

function trailingDotURL(url) {
    const parsed = luna.parseURL(url);
    if (!parsed || parsed.protocol !== "https:" || !isNYTHost(parsed.hostname)) { return null; }
    const authority = parsed.protocol + "//" + parsed.host;
    if (!parsed.href.startsWith(authority)) { return null; }
    const hostname = parsed.hostname.endsWith(".") ? parsed.hostname : parsed.hostname + ".";
    const dottedAuthority = parsed.protocol + "//" + hostname
        + (parsed.port ? ":" + parsed.port : "");
    return dottedAuthority + parsed.href.slice(authority.length);
}

function looksLikeConsentOrPrivacyPage(article) {
    const title = String(article.title || "").trim();
    if (/\b(privacy|terms of (service|use)|cookie|consent|data use)\b/i.test(title)) {
        return true;
    }
    const text = String(article.text || "").trim();
    return text.length < 1200
        || /\b(data privacy terms|privacy policy|terms of service|cookie policy)\b/i.test(text);
}

luna.register({
    classify({ url }) {
        try {
            const parsed = luna.parseURL(url);
            return isNYTHost(parsed.hostname) ? { kind: "article", confidence: 1 } : false;
        } catch (_) {
            return false;
        }
    },

    async ingest({ url }) {
        const requestURL = trailingDotURL(url);
        if (!requestURL) { return null; }

        let response;
        try {
            response = await luna.fetch({
                url: requestURL,
                userAgent: "safari",
                cookies: "none",
                timeout: 20,
                headers: { Accept: "text/html,application/xhtml+xml" },
            });
        } catch (_) {
            return null;
        }
        if (!response.ok || typeof response.text !== "string" || response.text.length === 0) {
            return null;
        }

        let article;
        try {
            // Resolve relative images and links against the canonical URL, not
            // the transport-only trailing-dot spelling.
            article = await LunaWeb.article(response.text, url);
        } catch (_) {
            return null;
        }
        if (!article || looksLikeConsentOrPrivacyPage(article)) { return null; }

        return {
            kind: "article",
            title: article.title,
            author: article.author,
            publishedAt: article.publishedAt,
            html: article.html,
            baseURL: url,
            leadImageURL: article.leadImageURL,
            excerpt: article.excerpt,
        };
    },
});
