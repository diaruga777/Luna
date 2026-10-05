/* luna-plugin
{"id":"app.luna.web","name":"Web articles and products","version":"1.1.1","api":1,
 "description":"Reads articles, remote documents and structured product pages using plugin-owned rules.",
 "produces":["article","product"],"match":{"any":true},"priority":-100,"capabilities":["fetch","html"]}
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

function excludedHost(host) {
    // Social feeds must never become articles merely because replies are long.
    return /(^|\.)(x\.com|twitter\.com|reddit\.com|redd\.it|instagram\.com|facebook\.com|tiktok\.com|youtube\.com|youtu\.be|bsky\.app)$/.test(host);
}
// BEGIN BUNDLED RETAIL_DATA HELPER
// Plugin-owned retail policy; edit here, independently of sibling Swift tables.
const LunaRetailData = {"sellers":[{"id":"amazon-us","name":"Amazon","region":"US","domain":"amazon.com","searchURL":"https://www.amazon.com/s?k={query}","acceptsGTIN":true,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"walmart-us","name":"Walmart","region":"US","domain":"walmart.com","searchURL":"https://www.walmart.com/search?q={query}","acceptsGTIN":true,"marketplace":false,"categories":["general"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"target-us","name":"Target","region":"US","domain":"target.com","searchURL":"https://www.target.com/s?searchTerm={query}","acceptsGTIN":true,"marketplace":false,"categories":["general"],"tier":1,"verified":true,"searchIsClientRendered":true},{"id":"costco-us","name":"Costco","region":"US","domain":"costco.com","searchURL":"https://www.costco.com/CatalogSearch?dept=All&keyword={query}","acceptsGTIN":null,"marketplace":false,"categories":["general"],"tier":1,"verified":false},{"id":"bestbuy-us","name":"Best Buy","region":"US","domain":"bestbuy.com","searchURL":"https://www.bestbuy.com/site/searchpage.jsp?st={query}","acceptsGTIN":true,"marketplace":false,"categories":["electronics","computers","appliances","gaming"],"tier":1,"verified":false},{"id":"homedepot-us","name":"The Home Depot","region":"US","domain":"homedepot.com","searchURL":"https://www.homedepot.com/s/{query}","acceptsGTIN":true,"marketplace":false,"categories":["diy-hardware","garden","appliances","home"],"tier":1,"verified":false},{"id":"lowes-us","name":"Lowe's","region":"US","domain":"lowes.com","searchURL":"https://www.lowes.com/search?searchTerm={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","garden","appliances","home"],"tier":1,"verified":false},{"id":"kohls-us","name":"Kohl's","region":"US","domain":"kohls.com","searchURL":"https://www.kohls.com/search.jsp?search={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","home","shoes"],"tier":2,"verified":false},{"id":"macys-us","name":"Macy's","region":"US","domain":"macys.com","searchURL":"https://www.macys.com/shop/search?keyword={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","home","jewelry","shoes"],"tier":2,"verified":false},{"id":"cvs-us","name":"CVS Pharmacy","region":"US","domain":"cvs.com","searchURL":"https://www.cvs.com/search?searchTerm={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":1,"verified":false},{"id":"walgreens-us","name":"Walgreens","region":"US","domain":"walgreens.com","searchURL":"https://www.walgreens.com/search/results.jsp?Ntt={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":1,"verified":false},{"id":"samsclub-us","name":"Sam's Club","region":"US","domain":"samsclub.com","searchURL":"https://www.samsclub.com/s/{query}","acceptsGTIN":true,"marketplace":false,"categories":["general","grocery"],"tier":1,"verified":false},{"id":"ebay-us","name":"eBay","region":"US","domain":"ebay.com","searchURL":"https://www.ebay.com/sch/i.html?_nkw={query}","acceptsGTIN":true,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"newegg-us","name":"Newegg","region":"US","domain":"newegg.com","searchURL":"https://www.newegg.com/p/pl?d={query}","acceptsGTIN":true,"marketplace":false,"categories":["electronics","computers","gaming"],"tier":2,"verified":true},{"id":"bhphoto-us","name":"B&H Photo Video","region":"US","domain":"bhphotovideo.com","searchURL":"https://www.bhphotovideo.com/c/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","computers"],"tier":2,"verified":false},{"id":"wayfair-us","name":"Wayfair","region":"US","domain":"wayfair.com","searchURL":"https://www.wayfair.com/keyword.php?keyword={query}","acceptsGTIN":null,"marketplace":false,"categories":["furniture","home"],"tier":2,"verified":false},{"id":"overstock-us","name":"Overstock","region":"US","domain":"overstock.com","searchURL":"https://www.overstock.com/search?keywords={query}","acceptsGTIN":null,"marketplace":false,"categories":["furniture","home"],"tier":2,"verified":false},{"id":"nordstrom-us","name":"Nordstrom","region":"US","domain":"nordstrom.com","searchURL":"https://www.nordstrom.com/sr?origin=keywordsearch&keyword={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","shoes","jewelry","luxury","beauty"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"jcpenney-us","name":"JCPenney","region":"US","domain":"jcpenney.com","searchURL":"https://www.jcpenney.com/s/{query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","home","shoes","jewelry"],"tier":2,"verified":false},{"id":"dickssportinggoods-us","name":"Dick's Sporting Goods","region":"US","domain":"dickssportinggoods.com","searchURL":"https://www.dickssportinggoods.com/search?searchTerm={query}","acceptsGTIN":null,"marketplace":false,"categories":["sports","outdoors"],"tier":1,"verified":false},{"id":"rei-us","name":"REI","region":"US","domain":"rei.com","searchURL":"https://www.rei.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["outdoors","sports"],"tier":2,"verified":false},{"id":"gamestop-us","name":"GameStop","region":"US","domain":"gamestop.com","searchURL":"https://www.gamestop.com/search/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["gaming"],"tier":2,"verified":false},{"id":"barnesandnoble-us","name":"Barnes & Noble","region":"US","domain":"barnesandnoble.com","searchURL":"https://www.barnesandnoble.com/s/{query}","acceptsGTIN":true,"marketplace":false,"categories":["books","media"],"tier":1,"verified":false},{"id":"bookshop-us","name":"Bookshop.org","region":"US","domain":"bookshop.org","searchURL":"https://bookshop.org/beta-search?keywords={query}","acceptsGTIN":true,"marketplace":false,"categories":["books"],"tier":2,"verified":true},{"id":"abebooks-us","name":"AbeBooks","region":"US","domain":"abebooks.com","searchURL":"https://www.abebooks.com/servlet/SearchResults?kn={query}","acceptsGTIN":true,"marketplace":true,"categories":["books","media"],"tier":2,"verified":true},{"id":"booksamillion-us","name":"Books-A-Million","region":"US","domain":"booksamillion.com","searchURL":"https://www.booksamillion.com/search?query={query}","acceptsGTIN":true,"marketplace":false,"categories":["books","media","toys"],"tier":2,"verified":false},{"id":"thriftbooks-us","name":"ThriftBooks","region":"US","domain":"thriftbooks.com","searchURL":"https://www.thriftbooks.com/browse/?b.search={query}","acceptsGTIN":true,"marketplace":false,"categories":["books","media"],"tier":2,"verified":true,"searchIsClientRendered":true},{"id":"petco-us","name":"Petco","region":"US","domain":"petco.com","searchURL":"https://www.petco.com/shop/en/petcostore/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["pets"],"tier":1,"verified":false},{"id":"petsmart-us","name":"PetSmart","region":"US","domain":"petsmart.com","searchURL":"https://www.petsmart.com/search/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["pets"],"tier":1,"verified":false},{"id":"staples-us","name":"Staples","region":"US","domain":"staples.com","searchURL":"https://www.staples.com/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["office"],"tier":1,"verified":false},{"id":"officedepot-us","name":"Office Depot OfficeMax","region":"US","domain":"officedepot.com","searchURL":"https://www.officedepot.com/catalog/search.do?keyword={query}","acceptsGTIN":null,"marketplace":false,"categories":["office"],"tier":2,"verified":false},{"id":"ulta-us","name":"Ulta Beauty","region":"US","domain":"ulta.com","searchURL":"https://www.ulta.com/shop/search?searchTerm={query}","acceptsGTIN":null,"marketplace":false,"categories":["beauty"],"tier":1,"verified":false},{"id":"sephora-us","name":"Sephora","region":"US","domain":"sephora.com","searchURL":"https://www.sephora.com/search?keyword={query}","acceptsGTIN":null,"marketplace":false,"categories":["beauty"],"tier":1,"verified":false},{"id":"acehardware-us","name":"Ace Hardware","region":"US","domain":"acehardware.com","searchURL":"https://www.acehardware.com/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","garden"],"tier":2,"verified":false},{"id":"menards-us","name":"Menards","region":"US","domain":"menards.com","searchURL":"https://www.menards.com/main/search.html?search={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","garden","home"],"tier":2,"verified":false},{"id":"tractorsupply-us","name":"Tractor Supply Co.","region":"US","domain":"tractorsupply.com","searchURL":"https://www.tractorsupply.com/tsc/search/{query}","acceptsGTIN":null,"marketplace":false,"categories":["garden","pets","auto","outdoors"],"tier":2,"verified":false},{"id":"academysports-us","name":"Academy Sports + Outdoors","region":"US","domain":"academy.com","searchURL":"https://www.academy.com/shop/search?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["sports","outdoors"],"tier":2,"verified":false},{"id":"footlocker-us","name":"Foot Locker","region":"US","domain":"footlocker.com","searchURL":"https://www.footlocker.com/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["shoes","fashion"],"tier":2,"verified":false},{"id":"chewy-us","name":"Chewy","region":"US","domain":"chewy.com","searchURL":"https://www.chewy.com/s?query={query}","acceptsGTIN":true,"marketplace":false,"categories":["pets"],"tier":1,"verified":false},{"id":"etsy-us","name":"Etsy","region":"US","domain":"etsy.com","searchURL":"https://www.etsy.com/search?q={query}","acceptsGTIN":false,"marketplace":true,"categories":["crafts","jewelry","home","general"],"tier":1,"verified":false},{"id":"michaels-us","name":"Michaels","region":"US","domain":"michaels.com","searchURL":"https://www.michaels.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["crafts"],"tier":2,"verified":false},{"id":"hobbylobby-us","name":"Hobby Lobby","region":"US","domain":"hobbylobby.com","searchURL":"https://www.hobbylobby.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["crafts","home"],"tier":2,"verified":false},{"id":"joann-us","name":"Joann Fabrics","region":"US","domain":"joann.com","searchURL":"https://www.joann.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["crafts"],"tier":2,"verified":false},{"id":"williamssonoma-us","name":"Williams-Sonoma","region":"US","domain":"williams-sonoma.com","searchURL":"https://www.williams-sonoma.com/search/results.html?words={query}","acceptsGTIN":null,"marketplace":false,"categories":["home","appliances"],"tier":2,"verified":false},{"id":"ikea-us","name":"IKEA (US)","region":"US","domain":"ikea.com","searchURL":"https://www.ikea.com/us/en/search/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["furniture","home"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"zappos-us","name":"Zappos","region":"US","domain":"zappos.com","searchURL":"https://www.zappos.com/search?term={query}","acceptsGTIN":null,"marketplace":false,"categories":["shoes","fashion"],"tier":2,"verified":false},{"id":"guitarcenter-us","name":"Guitar Center","region":"US","domain":"guitarcenter.com","searchURL":"https://www.guitarcenter.com/search?Ntt={query}","acceptsGTIN":null,"marketplace":false,"categories":["music-instruments"],"tier":2,"verified":false},{"id":"microcenter-us","name":"Micro Center","region":"US","domain":"microcenter.com","searchURL":"https://www.microcenter.com/search/search_results.aspx?Ntt={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","computers"],"tier":2,"verified":false},{"id":"autozone-us","name":"AutoZone","region":"US","domain":"autozone.com","searchURL":"https://www.autozone.com/search?searchText={query}","acceptsGTIN":null,"marketplace":false,"categories":["auto"],"tier":1,"verified":false},{"id":"oreillyauto-us","name":"O'Reilly Auto Parts","region":"US","domain":"oreillyauto.com","searchURL":"https://www.oreillyauto.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["auto"],"tier":2,"verified":false},{"id":"bathbodyworks-us","name":"Bath & Body Works","region":"US","domain":"bathandbodyworks.com","searchURL":"https://www.bathandbodyworks.com/search/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["beauty","home"],"tier":2,"verified":false},{"id":"basspro-us","name":"Bass Pro Shops","region":"US","domain":"basspro.com","searchURL":"https://www.basspro.com/shop/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["outdoors","sports"],"tier":2,"verified":false},{"id":"sallybeauty-us","name":"Sally Beauty","region":"US","domain":"sallybeauty.com","searchURL":"https://www.sallybeauty.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["beauty"],"tier":2,"verified":false},{"id":"qvc-us","name":"QVC","region":"US","domain":"qvc.com","searchURL":"https://www.qvc.com/search.html?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["general","home","jewelry","beauty"],"tier":2,"verified":false},{"id":"amazon-ca","name":"Amazon Canada","region":"CA","domain":"amazon.ca","searchURL":"https://www.amazon.ca/s?k={query}","acceptsGTIN":true,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"walmart-ca","name":"Walmart Canada","region":"CA","domain":"walmart.ca","searchURL":"https://www.walmart.ca/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["general"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"canadiantire-ca","name":"Canadian Tire","region":"CA","domain":"canadiantire.ca","searchURL":"https://www.canadiantire.ca/en/search-results.html?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["auto","diy-hardware","sports","outdoors","garden","home"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"bestbuy-ca","name":"Best Buy Canada","region":"CA","domain":"bestbuy.ca","searchURL":"https://www.bestbuy.ca/en-ca/search?search={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","computers","appliances","gaming"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"costco-ca","name":"Costco Canada","region":"CA","domain":"costco.ca","searchURL":"https://www.costco.ca/CatalogSearch?dept=All&keyword={query}","acceptsGTIN":null,"marketplace":false,"categories":["general"],"tier":1,"verified":false},{"id":"londondrugs-ca","name":"London Drugs","region":"CA","domain":"londondrugs.com","searchURL":"https://www.londondrugs.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty","electronics"],"tier":2,"verified":false},{"id":"shoppersdrugmart-ca","name":"Shoppers Drug Mart","region":"CA","domain":"shoppersdrugmart.ca","searchURL":"https://shop.shoppersdrugmart.ca/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":1,"verified":false},{"id":"indigo-ca","name":"Indigo (Chapters)","region":"CA","domain":"indigo.ca","searchURL":"https://www.indigo.ca/en-ca/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["books","media"],"tier":1,"verified":false},{"id":"sportchek-ca","name":"Sport Chek","region":"CA","domain":"sportchek.ca","searchURL":"https://www.sportchek.ca/search?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["sports","outdoors","shoes"],"tier":1,"verified":false},{"id":"hudsonsbay-ca","name":"Hudson's Bay","region":"CA","domain":"thebay.com","searchURL":"https://www.thebay.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","home","jewelry","shoes"],"tier":2,"verified":false},{"id":"homedepot-ca","name":"The Home Depot Canada","region":"CA","domain":"homedepot.ca","searchURL":"https://www.homedepot.ca/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","garden","appliances","home"],"tier":1,"verified":false},{"id":"rona-ca","name":"RONA (Lowe's Canada)","region":"CA","domain":"rona.ca","searchURL":"https://www.rona.ca/en/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","garden","home"],"tier":2,"verified":false},{"id":"staples-ca","name":"Staples Canada","region":"CA","domain":"staples.ca","searchURL":"https://www.staples.ca/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["office"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"michaels-ca","name":"Michaels Canada","region":"CA","domain":"michaels.ca","searchURL":"https://www.michaels.ca/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["crafts"],"tier":2,"verified":false},{"id":"petsmart-ca","name":"PetSmart Canada","region":"CA","domain":"petsmart.ca","searchURL":"https://www.petsmart.ca/search/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["pets"],"tier":1,"verified":false},{"id":"marks-ca","name":"Mark's","region":"CA","domain":"marks.com","searchURL":"https://www.marks.com/en/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","outdoors","shoes"],"tier":2,"verified":false},{"id":"mec-ca","name":"Mountain Equipment Company (MEC)","region":"CA","domain":"mec.ca","searchURL":"https://www.mec.ca/en/search?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["outdoors","sports"],"tier":2,"verified":false},{"id":"wellca-ca","name":"Well.ca","region":"CA","domain":"well.ca","searchURL":"https://well.ca/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["health","beauty","pharmacy","baby"],"tier":3,"verified":false},{"id":"simons-ca","name":"La Maison Simons","region":"CA","domain":"simons.ca","searchURL":"https://www.simons.ca/en/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","home"],"tier":2,"verified":false},{"id":"aritzia-ca","name":"Aritzia","region":"CA","domain":"aritzia.com","searchURL":"https://www.aritzia.com/en/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion"],"tier":3,"verified":false},{"id":"princessauto-ca","name":"Princess Auto","region":"CA","domain":"princessauto.com","searchURL":"https://www.princessauto.com/en/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","auto","outdoors"],"tier":3,"verified":false},{"id":"peaveymart-ca","name":"Peavey Mart","region":"CA","domain":"peaveymart.com","searchURL":"https://www.peaveymart.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["garden","diy-hardware","outdoors","pets"],"tier":3,"verified":false},{"id":"gianttiger-ca","name":"Giant Tiger","region":"CA","domain":"gianttiger.com","searchURL":"https://www.gianttiger.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["general"],"tier":2,"verified":false},{"id":"newegg-ca","name":"Newegg Canada","region":"CA","domain":"newegg.ca","searchURL":"https://www.newegg.ca/p/pl?d={query}","acceptsGTIN":true,"marketplace":false,"categories":["electronics","computers","gaming"],"tier":2,"verified":false},{"id":"structube-ca","name":"Structube","region":"CA","domain":"structube.com","searchURL":"https://www.structube.com/en_ca/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["furniture","home"],"tier":3,"verified":false},{"id":"thebrick-ca","name":"The Brick","region":"CA","domain":"thebrick.com","searchURL":"https://www.thebrick.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["furniture","appliances","home"],"tier":2,"verified":false},{"id":"leons-ca","name":"Leon's Furniture","region":"CA","domain":"leons.ca","searchURL":"https://www.leons.ca/pages/search-results?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["furniture","appliances","home"],"tier":2,"verified":false},{"id":"ebay-ca","name":"eBay Canada","region":"CA","domain":"ebay.ca","searchURL":"https://www.ebay.ca/sch/i.html?_nkw={query}","acceptsGTIN":true,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"amazon-uk","name":"Amazon UK","region":"GB","domain":"amazon.co.uk","searchURL":"https://www.amazon.co.uk/s?k={query}","acceptsGTIN":true,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"argos-uk","name":"Argos","region":"GB","domain":"argos.co.uk","searchURL":"https://www.argos.co.uk/search/{query}/","acceptsGTIN":null,"marketplace":false,"categories":["general","electronics","toys","home"],"tier":1,"verified":false},{"id":"currys-uk","name":"Currys","region":"GB","domain":"currys.co.uk","searchURL":"https://www.currys.co.uk/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","computers","appliances","gaming"],"tier":1,"verified":false},{"id":"johnlewis-uk","name":"John Lewis & Partners","region":"GB","domain":"johnlewis.com","searchURL":"https://www.johnlewis.com/search?search-term={query}","acceptsGTIN":null,"marketplace":false,"categories":["general","fashion","home","electronics","jewelry"],"tier":1,"verified":false},{"id":"tesco-uk","name":"Tesco","region":"GB","domain":"tesco.com","searchURL":"https://www.tesco.com/groceries/en-GB/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery","general","health","beauty"],"tier":1,"verified":false},{"id":"asda-uk","name":"Asda","region":"GB","domain":"groceries.asda.com","searchURL":"https://groceries.asda.com/search/{query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery","general"],"tier":1,"verified":false},{"id":"sainsburys-uk","name":"Sainsbury's","region":"GB","domain":"sainsburys.co.uk","searchURL":"https://www.sainsburys.co.uk/gol-ui/SearchResults/{query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery","general"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"boots-uk","name":"Boots","region":"GB","domain":"boots.com","searchURL":"https://www.boots.com/search?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":1,"verified":false},{"id":"superdrug-uk","name":"Superdrug","region":"GB","domain":"superdrug.com","searchURL":"https://www.superdrug.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":2,"verified":false},{"id":"bandq-uk","name":"B&Q","region":"GB","domain":"diy.com","searchURL":"https://www.diy.com/search?term={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","garden","home"],"tier":1,"verified":false},{"id":"screwfix-uk","name":"Screwfix","region":"GB","domain":"screwfix.com","searchURL":"https://www.screwfix.com/search?search={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware"],"tier":1,"verified":true},{"id":"wickes-uk","name":"Wickes","region":"GB","domain":"wickes.co.uk","searchURL":"https://www.wickes.co.uk/search?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","garden","home"],"tier":2,"verified":false},{"id":"homebase-uk","name":"Homebase","region":"GB","domain":"homebase.co.uk","searchURL":"https://www.homebase.co.uk/search?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","garden","home"],"tier":2,"verified":false},{"id":"very-uk","name":"Very","region":"GB","domain":"very.co.uk","searchURL":"https://www.very.co.uk/search?searchTerm={query}","acceptsGTIN":null,"marketplace":false,"categories":["general","fashion","electronics","home"],"tier":1,"verified":false},{"id":"next-uk","name":"Next","region":"GB","domain":"next.co.uk","searchURL":"https://www.next.co.uk/search?w={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","home","shoes"],"tier":1,"verified":false},{"id":"marksandspencer-uk","name":"Marks & Spencer","region":"GB","domain":"marksandspencer.com","searchURL":"https://www.marksandspencer.com/l/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","home","grocery"],"tier":1,"verified":false},{"id":"houseoffraser-uk","name":"House of Fraser","region":"GB","domain":"houseoffraser.co.uk","searchURL":"https://www.houseoffraser.co.uk/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","jewelry","beauty","home"],"tier":2,"verified":false},{"id":"selfridges-uk","name":"Selfridges","region":"GB","domain":"selfridges.com","searchURL":"https://www.selfridges.com/GB/en/search/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","luxury","beauty","jewelry"],"tier":2,"verified":false},{"id":"halfords-uk","name":"Halfords","region":"GB","domain":"halfords.com","searchURL":"https://www.halfords.com/search?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["auto","sports"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"dunelm-uk","name":"Dunelm","region":"GB","domain":"dunelm.com","searchURL":"https://www.dunelm.com/search?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["home","furniture"],"tier":2,"verified":false},{"id":"therange-uk","name":"The Range","region":"GB","domain":"therange.co.uk","searchURL":"https://www.therange.co.uk/catalogsearch/result/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["general","home","garden","crafts"],"tier":2,"verified":false},{"id":"robertdyas-uk","name":"Robert Dyas","region":"GB","domain":"robertdyas.co.uk","searchURL":"https://www.robertdyas.co.uk/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","home","appliances"],"tier":3,"verified":false},{"id":"toolstation-uk","name":"Toolstation","region":"GB","domain":"toolstation.com","searchURL":"https://www.toolstation.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware"],"tier":2,"verified":false},{"id":"ao-uk","name":"AO.com","region":"GB","domain":"ao.com","searchURL":"https://ao.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["appliances","electronics"],"tier":2,"verified":false},{"id":"richersounds-uk","name":"Richer Sounds","region":"GB","domain":"richersounds.com","searchURL":"https://www.richersounds.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics"],"tier":3,"verified":false},{"id":"waterstones-uk","name":"Waterstones","region":"GB","domain":"waterstones.com","searchURL":"https://www.waterstones.com/books/search/term/{query}","acceptsGTIN":null,"marketplace":false,"categories":["books"],"tier":1,"verified":false},{"id":"whsmith-uk","name":"WHSmith","region":"GB","domain":"whsmith.co.uk","searchURL":"https://www.whsmith.co.uk/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["books","office","media"],"tier":2,"verified":false},{"id":"game-uk","name":"GAME","region":"GB","domain":"game.co.uk","searchURL":"https://www.game.co.uk/en/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["gaming"],"tier":2,"verified":false},{"id":"smythstoys-uk","name":"Smyths Toys","region":"GB","domain":"smythstoys.com","searchURL":"https://www.smythstoys.com/uk/en-gb/catalogsearch/result/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["toys","baby"],"tier":1,"verified":false},{"id":"jdsports-uk","name":"JD Sports","region":"GB","domain":"jdsports.co.uk","searchURL":"https://www.jdsports.co.uk/search/{query}/","acceptsGTIN":null,"marketplace":false,"categories":["shoes","fashion","sports"],"tier":1,"verified":false},{"id":"sportsdirect-uk","name":"Sports Direct","region":"GB","domain":"sportsdirect.com","searchURL":"https://www.sportsdirect.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["sports","outdoors","shoes"],"tier":1,"verified":false},{"id":"decathlon-uk","name":"Decathlon UK","region":"GB","domain":"decathlon.co.uk","searchURL":"https://www.decathlon.co.uk/search?Ntt={query}","acceptsGTIN":null,"marketplace":false,"categories":["sports","outdoors"],"tier":2,"verified":false},{"id":"gooutdoors-uk","name":"GO Outdoors","region":"GB","domain":"gooutdoors.co.uk","searchURL":"https://www.gooutdoors.co.uk/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["outdoors","sports"],"tier":3,"verified":false},{"id":"petsathome-uk","name":"Pets at Home","region":"GB","domain":"petsathome.com","searchURL":"https://www.petsathome.com/search?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["pets"],"tier":1,"verified":false},{"id":"lookfantastic-uk","name":"Lookfantastic","region":"GB","domain":"lookfantastic.com","searchURL":"https://www.lookfantastic.com/search.list?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["beauty"],"tier":2,"verified":false},{"id":"asos-uk","name":"ASOS","region":"GB","domain":"asos.com","searchURL":"https://www.asos.com/search/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","shoes"],"tier":1,"verified":false},{"id":"boohoo-uk","name":"boohoo","region":"GB","domain":"boohoo.com","searchURL":"https://www.boohoo.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion"],"tier":2,"verified":false},{"id":"tkmaxx-uk","name":"TK Maxx","region":"GB","domain":"tkmaxx.com","searchURL":"https://www.tkmaxx.com/uk/en/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","home","shoes"],"tier":2,"verified":false},{"id":"matalan-uk","name":"Matalan","region":"GB","domain":"matalan.co.uk","searchURL":"https://www.matalan.co.uk/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","home"],"tier":2,"verified":false},{"id":"ocado-uk","name":"Ocado","region":"GB","domain":"ocado.com","searchURL":"https://www.ocado.com/search?entry={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery"],"tier":2,"verified":false},{"id":"morrisons-uk","name":"Morrisons","region":"GB","domain":"groceries.morrisons.com","searchURL":"https://groceries.morrisons.com/search?entry={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery"],"tier":1,"verified":false},{"id":"waitrose-uk","name":"Waitrose & Partners","region":"GB","domain":"waitrose.com","searchURL":"https://www.waitrose.com/ecom/shop/search?searchTerm={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery"],"tier":2,"verified":false},{"id":"ebay-uk","name":"eBay UK","region":"GB","domain":"ebay.co.uk","searchURL":"https://www.ebay.co.uk/sch/i.html?_nkw={query}","acceptsGTIN":true,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"argos-ie","name":"Argos Ireland","region":"IE","domain":"argos.ie","searchURL":"https://www.argos.ie/search/{query}/","acceptsGTIN":null,"marketplace":false,"categories":["general","electronics","toys","home"],"tier":1,"verified":false},{"id":"currys-ie","name":"Currys.ie","region":"IE","domain":"currys.ie","searchURL":"https://www.currys.ie/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","computers","appliances","gaming"],"tier":1,"verified":false},{"id":"woodies-ie","name":"Woodie's","region":"IE","domain":"woodies.ie","searchURL":"https://www.woodies.ie/catalogsearch/result/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","garden","home"],"tier":1,"verified":true,"searchIsClientRendered":true},{"id":"harveynorman-ie","name":"Harvey Norman Ireland","region":"IE","domain":"harveynorman.ie","searchURL":"https://www.harveynorman.ie/catalogsearch/result/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","appliances","furniture"],"tier":1,"verified":false},{"id":"didelectrical-ie","name":"DID Electrical","region":"IE","domain":"did.ie","searchURL":"https://www.did.ie/catalogsearch/result/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","appliances"],"tier":2,"verified":false},{"id":"elverys-ie","name":"Elverys","region":"IE","domain":"elverys.ie","searchURL":"https://www.elverys.ie/catalogsearch/result/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["sports","outdoors","shoes"],"tier":1,"verified":false},{"id":"boots-ie","name":"Boots Ireland","region":"IE","domain":"boots.ie","searchURL":"https://www.boots.ie/search?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":1,"verified":false},{"id":"tesco-ie","name":"Tesco Ireland","region":"IE","domain":"tesco.ie","searchURL":"https://www.tesco.ie/groceries/en-IE/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery","general"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"dunnesstores-ie","name":"Dunnes Stores","region":"IE","domain":"dunnesstores.com","searchURL":"https://www.dunnesstores.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery","fashion","home"],"tier":1,"verified":false},{"id":"smythstoys-ie","name":"Smyths Toys Ireland","region":"IE","domain":"smythstoys.com","searchURL":"https://www.smythstoys.com/ie/en-ie/catalogsearch/result/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["toys","baby"],"tier":1,"verified":false},{"id":"easons-ie","name":"Eason","region":"IE","domain":"easons.com","searchURL":"https://www.easons.com/catalogsearch/result/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["books","media","office"],"tier":2,"verified":false},{"id":"littlewoodsireland-ie","name":"Littlewoods Ireland","region":"IE","domain":"littlewoodsireland.ie","searchURL":"https://www.littlewoodsireland.ie/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["general","fashion","electronics","home"],"tier":2,"verified":false},{"id":"lifestylesports-ie","name":"Life Style Sports","region":"IE","domain":"lifestylesports.com","searchURL":"https://www.lifestylesports.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["sports","shoes","fashion"],"tier":2,"verified":false},{"id":"arnotts-ie","name":"Arnotts","region":"IE","domain":"arnotts.com","searchURL":"https://www.arnotts.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","jewelry","home","beauty"],"tier":2,"verified":false},{"id":"brownthomas-ie","name":"Brown Thomas","region":"IE","domain":"brownthomas.com","searchURL":"https://www.brownthomas.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["luxury","fashion","beauty","jewelry"],"tier":2,"verified":false},{"id":"mcelhinneys-ie","name":"McElhinneys","region":"IE","domain":"mcelhinneys.com","searchURL":"https://www.mcelhinneys.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","home","furniture"],"tier":3,"verified":false},{"id":"meaghers-ie","name":"Meaghers Pharmacy","region":"IE","domain":"meaghers.ie","searchURL":"https://www.meaghers.ie/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":3,"verified":false},{"id":"amazon-au","name":"Amazon Australia","region":"AU","domain":"amazon.com.au","searchURL":"https://www.amazon.com.au/s?k={query}","acceptsGTIN":true,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"woolworths-au","name":"Woolworths","region":"AU","domain":"woolworths.com.au","searchURL":"https://www.woolworths.com.au/shop/search/products?searchTerm={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery","general"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"coles-au","name":"Coles","region":"AU","domain":"coles.com.au","searchURL":"https://www.coles.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery","general"],"tier":1,"verified":false},{"id":"kmart-au","name":"Kmart Australia","region":"AU","domain":"kmart.com.au","searchURL":"https://www.kmart.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["general","home","toys","fashion"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"target-au","name":"Target Australia","region":"AU","domain":"target.com.au","searchURL":"https://www.target.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["general","fashion","home","toys"],"tier":1,"verified":false},{"id":"bigw-au","name":"Big W","region":"AU","domain":"bigw.com.au","searchURL":"https://www.bigw.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["general","toys","home","fashion"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"jbhifi-au","name":"JB Hi-Fi","region":"AU","domain":"jbhifi.com.au","searchURL":"https://www.jbhifi.com.au/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","computers","gaming","media"],"tier":1,"verified":true},{"id":"harveynorman-au","name":"Harvey Norman","region":"AU","domain":"harveynorman.com.au","searchURL":"https://www.harveynorman.com.au/catalogsearch/result/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","appliances","furniture","computers"],"tier":1,"verified":false},{"id":"thegoodguys-au","name":"The Good Guys","region":"AU","domain":"thegoodguys.com.au","searchURL":"https://www.thegoodguys.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["appliances","electronics"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"officeworks-au","name":"Officeworks","region":"AU","domain":"officeworks.com.au","searchURL":"https://www.officeworks.com.au/shop/officeworks/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["office","electronics"],"tier":1,"verified":false},{"id":"bunnings-au","name":"Bunnings Warehouse","region":"AU","domain":"bunnings.com.au","searchURL":"https://www.bunnings.com.au/search/products?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","garden","home"],"tier":1,"verified":false},{"id":"myer-au","name":"Myer","region":"AU","domain":"myer.com.au","searchURL":"https://www.myer.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","home","jewelry","beauty"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"davidjones-au","name":"David Jones","region":"AU","domain":"davidjones.com","searchURL":"https://www.davidjones.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","luxury","jewelry","beauty"],"tier":1,"verified":false},{"id":"chemistwarehouse-au","name":"Chemist Warehouse","region":"AU","domain":"chemistwarehouse.com.au","searchURL":"https://www.chemistwarehouse.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"priceline-au","name":"Priceline","region":"AU","domain":"priceline.com.au","searchURL":"https://www.priceline.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":2,"verified":false},{"id":"rebelsport-au","name":"Rebel Sport","region":"AU","domain":"rebelsport.com.au","searchURL":"https://www.rebelsport.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["sports","outdoors","shoes"],"tier":1,"verified":false},{"id":"bcf-au","name":"BCF (Boating Camping Fishing)","region":"AU","domain":"bcf.com.au","searchURL":"https://www.bcf.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["outdoors","sports"],"tier":2,"verified":false},{"id":"anaconda-au","name":"Anaconda","region":"AU","domain":"anacondastores.com","searchURL":"https://www.anacondastores.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["outdoors","sports"],"tier":2,"verified":false},{"id":"catch-au","name":"Catch.com.au","region":"AU","domain":"catch.com.au","searchURL":"https://www.catch.com.au/search?keyword={query}","acceptsGTIN":null,"marketplace":true,"categories":["general"],"tier":2,"verified":false},{"id":"kogan-au","name":"Kogan.com","region":"AU","domain":"kogan.com","searchURL":"https://www.kogan.com/au/shop/search/?q={query}","acceptsGTIN":null,"marketplace":true,"categories":["electronics","general","appliances"],"tier":2,"verified":false},{"id":"mydeal-au","name":"MyDeal","region":"AU","domain":"mydeal.com.au","searchURL":"https://www.mydeal.com.au/catalogsearch/result?q={query}","acceptsGTIN":null,"marketplace":true,"categories":["furniture","home","general"],"tier":3,"verified":false},{"id":"petbarn-au","name":"Petbarn","region":"AU","domain":"petbarn.com.au","searchURL":"https://www.petbarn.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["pets"],"tier":1,"verified":false},{"id":"supercheapauto-au","name":"Supercheap Auto","region":"AU","domain":"supercheapauto.com.au","searchURL":"https://www.supercheapauto.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["auto","outdoors"],"tier":1,"verified":false},{"id":"repco-au","name":"Repco","region":"AU","domain":"repco.com.au","searchURL":"https://www.repco.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["auto"],"tier":2,"verified":false},{"id":"autobarn-au","name":"Autobarn","region":"AU","domain":"autobarn.com.au","searchURL":"https://www.autobarn.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["auto"],"tier":3,"verified":false},{"id":"cottonon-au","name":"Cotton On","region":"AU","domain":"cottonon.com","searchURL":"https://cottonon.com/AU/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion"],"tier":2,"verified":false},{"id":"asos-au","name":"ASOS (AU)","region":"AU","domain":"asos.com","searchURL":"https://www.asos.com/au/search/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","shoes"],"tier":1,"verified":false},{"id":"booktopia-au","name":"Booktopia","region":"AU","domain":"booktopia.com.au","searchURL":"https://www.booktopia.com.au/search.ep?keywords={query}","acceptsGTIN":null,"marketplace":false,"categories":["books"],"tier":1,"verified":false},{"id":"dymocks-au","name":"Dymocks","region":"AU","domain":"dymocks.com.au","searchURL":"https://www.dymocks.com.au/searchresult?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["books"],"tier":2,"verified":false},{"id":"spotlight-au","name":"Spotlight","region":"AU","domain":"spotlightstores.com","searchURL":"https://www.spotlightstores.com/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["crafts","home"],"tier":2,"verified":false},{"id":"ebgames-au","name":"EB Games Australia","region":"AU","domain":"ebgames.com.au","searchURL":"https://www.ebgames.com.au/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["gaming"],"tier":2,"verified":false},{"id":"babybunting-au","name":"Baby Bunting","region":"AU","domain":"babybunting.com.au","searchURL":"https://www.babybunting.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["baby"],"tier":1,"verified":false},{"id":"adairs-au","name":"Adairs","region":"AU","domain":"adairs.com.au","searchURL":"https://www.adairs.com.au/search/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["home","furniture"],"tier":2,"verified":false},{"id":"fantasticfurniture-au","name":"Fantastic Furniture","region":"AU","domain":"fantasticfurniture.com.au","searchURL":"https://www.fantasticfurniture.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["furniture","home"],"tier":2,"verified":false},{"id":"ikea-au","name":"IKEA (Australia)","region":"AU","domain":"ikea.com","searchURL":"https://www.ikea.com/au/en/search/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["furniture","home"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"ebay-au","name":"eBay Australia","region":"AU","domain":"ebay.com.au","searchURL":"https://www.ebay.com.au/sch/i.html?_nkw={query}","acceptsGTIN":true,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"binglee-au","name":"Bing Lee","region":"AU","domain":"binglee.com.au","searchURL":"https://www.binglee.com.au/search?q={query}","acceptsGTIN":true,"marketplace":false,"categories":["electronics","appliances","computers"],"tier":1,"verified":true},{"id":"appliancesonline-au","name":"Appliances Online","region":"AU","domain":"appliancesonline.com.au","searchURL":"https://www.appliancesonline.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["appliances"],"tier":2,"verified":true,"searchIsClientRendered":true},{"id":"retravision-au","name":"Retravision","region":"AU","domain":"retravision.com.au","searchURL":"https://www.retravision.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","appliances"],"tier":2,"verified":false},{"id":"costco-au","name":"Costco Australia","region":"AU","domain":"costco.com.au","searchURL":"https://www.costco.com.au/search/{query}","acceptsGTIN":null,"marketplace":false,"categories":["general"],"tier":1,"verified":true,"searchIsClientRendered":true},{"id":"betta-au","name":"Betta Home Living","region":"AU","domain":"betta.com.au","searchURL":"https://www.betta.com.au/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["appliances","electronics"],"tier":2,"verified":true,"searchIsClientRendered":true},{"id":"thewarehouse-nz","name":"The Warehouse","region":"NZ","domain":"thewarehouse.co.nz","searchURL":"https://www.thewarehouse.co.nz/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["general","home","toys","electronics"],"tier":1,"verified":true},{"id":"noelleeming-nz","name":"Noel Leeming","region":"NZ","domain":"noelleeming.co.nz","searchURL":"https://www.noelleeming.co.nz/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","appliances","computers"],"tier":1,"verified":true},{"id":"harveynorman-nz","name":"Harvey Norman NZ","region":"NZ","domain":"harveynorman.co.nz","searchURL":"https://www.harveynorman.co.nz/catalogsearch/result/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","appliances","furniture"],"tier":1,"verified":false},{"id":"jbhifi-nz","name":"JB Hi-Fi NZ","region":"NZ","domain":"jbhifi.co.nz","searchURL":"https://www.jbhifi.co.nz/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","computers","gaming","media"],"tier":1,"verified":false},{"id":"woolworths-nz","name":"Woolworths NZ (Countdown)","region":"NZ","domain":"woolworths.co.nz","searchURL":"https://www.woolworths.co.nz/shop/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery","general"],"tier":1,"verified":false},{"id":"paknsave-nz","name":"PAK'nSAVE","region":"NZ","domain":"paknsave.co.nz","searchURL":"https://www.paknsave.co.nz/shop/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery"],"tier":1,"verified":false},{"id":"newworld-nz","name":"New World","region":"NZ","domain":"newworld.co.nz","searchURL":"https://www.newworld.co.nz/shop/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery"],"tier":1,"verified":false},{"id":"farmers-nz","name":"Farmers","region":"NZ","domain":"farmers.co.nz","searchURL":"https://www.farmers.co.nz/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["fashion","home","beauty","baby"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"mitre10-nz","name":"Mitre 10","region":"NZ","domain":"mitre10.co.nz","searchURL":"https://www.mitre10.co.nz/shop/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","garden","home"],"tier":1,"verified":false},{"id":"bunnings-nz","name":"Bunnings Warehouse NZ","region":"NZ","domain":"bunnings.co.nz","searchURL":"https://www.bunnings.co.nz/search/products?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["diy-hardware","garden","home"],"tier":1,"verified":false},{"id":"pbtech-nz","name":"PB Tech","region":"NZ","domain":"pbtech.co.nz","searchURL":"https://www.pbtech.co.nz/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","computers"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"briscoes-nz","name":"Briscoes","region":"NZ","domain":"briscoes.co.nz","searchURL":"https://www.briscoes.co.nz/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["home","appliances","outdoors"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"rebelsport-nz","name":"Rebel Sport NZ","region":"NZ","domain":"rebelsport.co.nz","searchURL":"https://www.rebelsport.co.nz/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["sports","shoes","outdoors"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"torpedo7-nz","name":"Torpedo7","region":"NZ","domain":"torpedo7.co.nz","searchURL":"https://www.torpedo7.co.nz/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["outdoors","sports"],"tier":2,"verified":false},{"id":"kmart-nz","name":"Kmart NZ","region":"NZ","domain":"kmart.co.nz","searchURL":"https://www.kmart.co.nz/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["general","home","toys","fashion"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"smithscity-nz","name":"Smiths City","region":"NZ","domain":"smithscity.co.nz","searchURL":"https://www.smithscity.co.nz/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["furniture","appliances","electronics"],"tier":2,"verified":false},{"id":"ebgames-nz","name":"EB Games NZ","region":"NZ","domain":"ebgames.co.nz","searchURL":"https://www.ebgames.co.nz/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["gaming"],"tier":2,"verified":false},{"id":"paperplus-nz","name":"Paper Plus","region":"NZ","domain":"paperplus.co.nz","searchURL":"https://www.paperplus.co.nz/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["books","office","media"],"tier":2,"verified":false},{"id":"whitcoulls-nz","name":"Whitcoulls","region":"NZ","domain":"whitcoulls.co.nz","searchURL":"https://www.whitcoulls.co.nz/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["books","media","office"],"tier":2,"verified":false},{"id":"animates-nz","name":"Animates","region":"NZ","domain":"animates.co.nz","searchURL":"https://www.animates.co.nz/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["pets"],"tier":1,"verified":false},{"id":"trademe-nz","name":"Trade Me","region":"NZ","domain":"trademe.co.nz","searchURL":"https://www.trademe.co.nz/a/marketplace/search?searchString={query}","acceptsGTIN":null,"marketplace":true,"categories":["general"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"amazon-sg","name":"Amazon Singapore","region":"SG","domain":"amazon.sg","searchURL":"https://www.amazon.sg/s?k={query}","acceptsGTIN":true,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"lazada-sg","name":"Lazada Singapore","region":"SG","domain":"lazada.sg","searchURL":"https://www.lazada.sg/catalog/?q={query}","acceptsGTIN":null,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"shopee-sg","name":"Shopee Singapore","region":"SG","domain":"shopee.sg","searchURL":"https://shopee.sg/search?keyword={query}","acceptsGTIN":null,"marketplace":true,"categories":["general"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"courts-sg","name":"Courts","region":"SG","domain":"courts.com.sg","searchURL":"https://www.courts.com.sg/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","appliances","furniture"],"tier":2,"verified":false},{"id":"challenger-sg","name":"Challenger","region":"SG","domain":"challenger.sg","searchURL":"https://www.challenger.sg/catalogsearch/result/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","computers"],"tier":2,"verified":false},{"id":"fairprice-sg","name":"FairPrice","region":"SG","domain":"fairprice.com.sg","searchURL":"https://www.fairprice.com.sg/search?query={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery","general"],"tier":1,"verified":false},{"id":"guardian-sg","name":"Guardian","region":"SG","domain":"guardian.sg","searchURL":"https://www.guardian.sg/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":2,"verified":false},{"id":"watsons-sg","name":"Watsons Singapore","region":"SG","domain":"watsons.com.sg","searchURL":"https://www.watsons.com.sg/search?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":2,"verified":false},{"id":"takealot-za","name":"Takealot","region":"ZA","domain":"takealot.com","searchURL":"https://www.takealot.com/all?qsearch={query}","acceptsGTIN":null,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"makro-za","name":"Makro","region":"ZA","domain":"makro.co.za","searchURL":"https://www.makro.co.za/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["general","electronics","appliances"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"game-za","name":"Game (South Africa)","region":"ZA","domain":"game.co.za","searchURL":"https://www.game.co.za/game-za/search/?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["general","electronics","toys","appliances"],"tier":1,"verified":false},{"id":"woolworths-za","name":"Woolworths South Africa","region":"ZA","domain":"woolworths.co.za","searchURL":"https://www.woolworths.co.za/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery","fashion","home"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"clicks-za","name":"Clicks","region":"ZA","domain":"clicks.co.za","searchURL":"https://www.clicks.co.za/search?text={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":1,"verified":false},{"id":"dischem-za","name":"Dis-Chem","region":"ZA","domain":"dischem.co.za","searchURL":"https://www.dischem.co.za/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["pharmacy","health","beauty"],"tier":1,"verified":false},{"id":"incredible-za","name":"Incredible Connection","region":"ZA","domain":"incredible.co.za","searchURL":"https://www.incredible.co.za/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","computers"],"tier":2,"verified":false},{"id":"amazon-in","name":"Amazon India","region":"IN","domain":"amazon.in","searchURL":"https://www.amazon.in/s?k={query}","acceptsGTIN":true,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"flipkart-in","name":"Flipkart","region":"IN","domain":"flipkart.com","searchURL":"https://www.flipkart.com/search?q={query}","acceptsGTIN":true,"marketplace":true,"categories":["general"],"tier":1,"verified":false},{"id":"myntra-in","name":"Myntra","region":"IN","domain":"myntra.com","searchURL":"https://www.myntra.com/search?q={query}","acceptsGTIN":null,"marketplace":true,"categories":["fashion","shoes"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"bigbasket-in","name":"BigBasket","region":"IN","domain":"bigbasket.com","searchURL":"https://www.bigbasket.com/ps/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["grocery"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"croma-in","name":"Croma","region":"IN","domain":"croma.com","searchURL":"https://www.croma.com/search/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","appliances","computers"],"tier":1,"verified":false,"searchIsClientRendered":true},{"id":"reliancedigital-in","name":"Reliance Digital","region":"IN","domain":"reliancedigital.in","searchURL":"https://www.reliancedigital.in/search?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["electronics","appliances","computers"],"tier":1,"verified":false},{"id":"nykaa-in","name":"Nykaa","region":"IN","domain":"nykaa.com","searchURL":"https://www.nykaa.com/search/result/?q={query}","acceptsGTIN":null,"marketplace":false,"categories":["beauty","health"],"tier":1,"verified":false},{"id":"tatacliq-in","name":"Tata CLiQ","region":"IN","domain":"tatacliq.com","searchURL":"https://www.tatacliq.com/search/?searchCategory=all&text={query}","acceptsGTIN":null,"marketplace":true,"categories":["general","fashion","electronics"],"tier":2,"verified":false}],"categories":{"appliances":["appliance","refrigerator","fridge","dishwasher","washing machine","dryer","microwave","oven","cooktop","freezer","vacuum","air fryer","washer"],"auto":["automotive","car parts","tyre","tire","motor oil","windscreen","car battery","brake pads","auto part","vehicle","engine oil"],"baby":["baby","infant","toddler","nursery","stroller","pushchair","nappy","diaper","pram","car seat"],"beauty":["beauty","cosmetic","makeup","skincare","fragrance","perfume","shampoo","moisturiser","moisturizer","lipstick","haircare","nail polish","toiletries"],"books":["book","bookstore","paperback","hardcover","hardback","novel","isbn","audiobook","textbook","ebook","e-book","literature","fiction","nonfiction","non-fiction","cookbook","comic","manga","biography","self-help","memoir"],"computers":["laptop","notebook computer","desktop pc","monitor","keyboard","mouse","ssd","graphics card","cpu","ram","printer","macbook","computer","computing","chromebook"],"crafts":["craft","sewing","knitting","yarn","scrapbook","quilting","beading","embroidery","fabric"],"electronics":["electronics","headphone","earbud","speaker","television","camera","smartphone","tablet","smartwatch","console","soundbar","charger","electronic","audio","headset","earphone","tv","hdtv"],"fashion":["clothing","apparel","fashion","dress","shirt","jacket","coat","jeans","trousers","sweater","hoodie","skirt","clothes","garment","menswear","womenswear","t-shirt"],"furniture":["furniture","sofa","couch","armchair","mattress","bed frame","wardrobe","bookcase","dining table","desk","nightstand","dresser","shelving"],"gaming":["gaming","playstation","xbox","nintendo","video game","videogame","controller","steam deck","gamepad"],"garden":["garden","lawn","mower","plant pot","seeds","greenhouse","patio","barbecue","bbq","gardening","outdoor living"],"grocery":["grocery","groceries","food","snack","coffee beans","tea bags","cereal","pantry","beverage","drink","candy"],"health":["health","supplement","vitamin","fitness tracker","first aid","wellness","nutrition","medical","personal care"],"home":["home","kitchen","cookware","bedding","towel","cushion","curtain","storage box","homeware","kettle","blender","household","decor"],"jewelry":["jewelry","jewellery","necklace","bracelet","earring","watch","engagement ring","pendant","wristwatch"],"luxury":["luxury","designer","couture","haute"],"media":["blu-ray","dvd","vinyl","cd album","boxset","box set","movie","film","music","album","soundtrack"],"office":["office","stationery","notebook paper","printer paper","pen","pencil","binder","envelope","school supply","stationary"],"outdoors":["outdoor","camping","tent","hiking","backpack","sleeping bag","kayak","fishing","cooler","binoculars"],"pets":["pet","dog","cat","puppy","kitten","aquarium","litter box","pet supply","dog food","cat food"],"pharmacy":["pharmacy","chemist","prescription","medicine","painkiller","ibuprofen","paracetamol"],"shoes":["shoe","sneaker","trainer","boot","sandal","loafer","heels","footwear"],"sports":["sport","football","soccer","basketball","running","gym","yoga","cycling","bicycle","tennis","golf","sporting good","athletic","exercise","workout"],"toys":["toy","lego","puzzle","board game","doll","action figure","plush","building set","figurine","playset"],"diy-hardware":["hardware","diy","power tool","drill","hammer","screwdriver","timber","lumber","paint","plumbing","toolbox","tool","home improvement"],"music-instruments":["guitar","piano","keyboard instrument","drum kit","violin","ukulele","amplifier","synthesizer","instrument"]},"amazon":{"amazon.com":"USD","amazon.ca":"CAD","amazon.com.mx":"MXN","amazon.com.br":"BRL","amazon.co.uk":"GBP","amazon.de":"EUR","amazon.fr":"EUR","amazon.it":"EUR","amazon.es":"EUR","amazon.nl":"EUR","amazon.se":"SEK","amazon.pl":"PLN","amazon.com.tr":"TRY","amazon.com.be":"EUR","amazon.ie":"EUR","amazon.co.jp":"JPY","amazon.in":"INR","amazon.com.au":"AUD","amazon.sg":"SGD","amazon.ae":"AED","amazon.sa":"SAR","amazon.eg":"EGP","amazon.co.za":"ZAR"},"currencies":{"US":"USD","GB":"GBP","CA":"CAD","AU":"AUD","NZ":"NZD","IE":"EUR","IN":"INR","SG":"SGD","ZA":"ZAR"}};
// END BUNDLED RETAIL_DATA HELPER
// BEGIN BUNDLED SHOP HELPER
// Product interpretation and discovery. This source is embedded only in web.js.
const LunaShop = (() => {
    const data = LunaRetailData;
    const hostMatches = (host, domain) => host === domain || host.endsWith('.' + domain);
    const sellerFor = host => data.sellers.find(s => hostMatches(host, s.domain));
    const attr = (doc, selector, name) => { const n = doc.querySelector(selector); return n && (name ? n.getAttribute(name) : n.textContent); };
    const clean = v => LunaWeb.clean(v || '');
    const absolute = (v, base) => LunaWeb.absoluteURL(v, base);
    function amount(raw) {
        if (typeof raw === 'number') return raw > 0 ? String(raw) : null;
        const parsed = LunaWeb.price(String(raw));
        const value = parsed && parsed.amount || String(raw || '').trim();
        return /^\d+(\.\d+)?$/.test(value) && Number(value) > 0 ? value : null;
    }
    function walk(value, names, depth = 0) {
        if (!value || typeof value !== 'object' || depth > 16) return null;
        for (const name of names) {
            if (value[name] !== undefined) {
                const v = value[name];
                if (typeof v === 'string' || typeof v === 'number') return v;
                const nested = walk(v, ['price', 'value', 'amount'], depth + 1);
                if (nested !== null) return nested;
            }
        }
        for (const key of Object.keys(value).sort()) {
            const found = walk(value[key], names, depth + 1);
            if (found !== null) return found;
        }
        return null;
    }
    function currencyCode(value) {
        if(typeof value==='string' && /^[A-Z]{3}$/i.test(value))return value.toUpperCase();
        if(value && typeof value==='object')return currencyCode(value.code || value.isoCode || value.currencyCode);
        return null;
    }
    // Interpret JSON data only; page scripts are never evaluated in the plugin VM.
    function embeddedData(doc) {
        const values=luna.html.jsonScripts(doc,'application/json');
        for(const script of doc.querySelectorAll('script:not([src])')) {
            if(/(?:application\/(?:ld\+)?json)/i.test(script.getAttribute('type')||''))continue;
            const source=script.innerHTML;
            if(!/(?:window\.|__NEXT_DATA__|__INITIAL_STATE__|__PRELOADED_STATE__)/.test(source))continue;
            let start=-1,depth=0,quoted=false,escaped=false;
            for(let i=0;i<source.length;i++) {
                const ch=source[i];
                if(start<0){if(ch==='{'){start=i;depth=1;}continue;}
                if(quoted){if(escaped)escaped=false;else if(ch==='\\')escaped=true;else if(ch==='"')quoted=false;continue;}
                if(ch==='"'){quoted=true;continue;}
                if(ch==='{')depth++;
                if(ch==='}') {depth--;if(depth===0){try{values.push(JSON.parse(source.slice(start,i+1)));}catch(_){}start=-1;}}
            }
        }
        return values;
    }
    function embeddedPrice(value,depth=0) {
        if(!value || typeof value!=='object' || depth>16)return null;
        const currency=currencyCode(value.priceCurrency || value.currencyCode || value.currencyIso || value.currencyUnit || value.currency);
        const price=amount(value.price || value.currentPrice || value.salePrice || value.value || value.amount);
        if(currency && price)return {amount:price,currency};
        // Stable preference; a former/list price or installment cannot become today's price.
        const preferred=['product','currentPrice','salePrice','price','prices','base'];
        const keys=[...preferred,...Object.keys(value).sort().filter(k=>!preferred.includes(k))];
        for(const key of keys) {
            if(/wasprice|listprice|regularprice|reg_retail|installment|instalment|paymentoption|recommend|related/i.test(key))continue;
            const found=embeddedPrice(value[key],depth+1);if(found)return found;
        }
        return null;
    }
    function shoppingURL(url) {
        const u = luna.parseURL(url);
        return u && hostMatches(u.hostname, 'google.com') && u.pathname === '/search'
            && (/(?:^|&)(?:tbm=shop|udm=28|ibp=oshop)(?:&|$)/.test(u.search.slice(1)) || /(?:^|&)(?:prds|shopmd)(?:=|&|$)/.test(u.search.slice(1)));
    }
    function query(url, name) {
        const u = luna.parseURL(url);
        const entry = (u.search || '').slice(1).split('&').find(x => x.split('=')[0] === name);
        try { return entry ? decodeURIComponent(entry.slice(entry.indexOf('=') + 1).replace(/\+/g, ' ')) : null; } catch (_) { return null; }
    }
    function googleSeller(raw, base) {
        let url = absolute(raw, base), u = luna.parseURL(url || '');
        if (!u) return null;
        if (hostMatches(u.hostname, 'google.com')) url = query(url, 'url') || query(url, 'q') || query(url, 'adurl');
        u = luna.parseURL(url || '');
        if (!u || !/^https?:$/.test(u.protocol) || ['google.com','g.co','googleusercontent.com','gstatic.com'].some(d => hostMatches(u.hostname,d))) return null;
        const queryParts = u.search.slice(1).split('&').filter(x => x && !/^(utm_[^=]*|srsltid|gclid)=/i.test(x));
        return u.protocol + '//' + u.host + u.pathname + (queryParts.length ? '?' + queryParts.join('&') : '');
    }
    function googleProduct(doc, url) {
        if (!shoppingURL(url)) return null;
        const seen = new Set(), sellers = [];
        for (const a of doc.querySelectorAll('a[href]')) {
            const target = googleSeller(a.getAttribute('href'), url);
            if (!target) continue;
            const u = luna.parseURL(target), key = u.hostname + u.pathname;
            if (seen.has(key)) continue;
            let n = a, price = null;
            for (let i=0; i<6 && n; i++, n=n.parentElement) {
                // Do not let a whole search grid donate a price to an unrelated link.
                if (n.querySelectorAll('a[href]').length > 12) break;
                const m = /(?:AU\$|A\$|US\$|CA\$|NZ\$|\$|£|€|¥)\s*[0-9][0-9.,]*/i.exec(n.textContent);
                if (m) { price = LunaWeb.price(m[0]); if (price && /^\$/.test(m[0]) && u.hostname.endsWith('.au')) price.currency='AUD'; break; }
            }
            if (!price || !amount(price.amount)) continue;
            seen.add(key); sellers.push({url:target,price});
            if (sellers.length === 20) break;
        }
        if (!sellers.length) return null;
        const price = sellers[0].price;
        const sameCurrency = sellers.filter(s => s.price.currency === price.currency);
        const best = sameCurrency.reduce((a,b) => Number(a.price.amount)<Number(b.price.amount)?a:b);
        return {kind:'product',name:clean(LunaWeb.meta(doc).title || query(url,'q') || 'Product').replace(/ - Google (Shopping|Search)$/,'').slice(0,300),price:best.price,sellers:sameCurrency};
    }
    function product(doc, url) {
        if (shoppingURL(url)) return googleProduct(doc,url);
        const meta = LunaWeb.meta(doc), host = luna.parseURL(url).hostname;
        const linked = LunaWeb.jsonLD(doc).find(v => v && [].concat(v['@type'] || []).includes('Product'));
        const offers = linked ? [].concat(linked.offers || []).flatMap(o => o && o.offers ? [].concat(o.offers) : [o]) : [];
        let offer = offers.find(o => o && amount(o.price || o.lowPrice)) || {};
        let value = amount(offer.price || offer.lowPrice), currency = offer.priceCurrency;
        const embedded = embeddedData(doc);
        const next = attr(doc,'script#__NEXT_DATA__');
        if (next) { try { embedded.unshift(JSON.parse(next)); } catch (_) {} }
        const amazon = Object.keys(data.amazon).find(d => hostMatches(host,d));
        if (amazon) {
            const html = doc.documentElement.outerHTML;
            const hit = /"priceAmount"\s*:\s*([\d.]+)/.exec(html) || /"displayPrice"\s*:\s*"([^"]+)"/.exec(html);
            const buybox = hit && hit[1] || attr(doc,'#corePriceDisplay_desktop_feature_div .a-offscreen, #corePrice_feature_div .a-offscreen, #corePriceDisplay_mobile_feature_div .a-offscreen, #buybox .a-offscreen, #price_inside_buybox');
            value = amount(buybox) || value;
            currency = (/"(?:currencyCode|priceCurrency)"\s*:\s*"([A-Z]{3})"/i.exec(html)||[])[1] || currency || data.amazon[amazon];
        }
        const target = hostMatches(host,'target.com'), walmart = hostMatches(host,'walmart.com');
        if (target || walmart) {
            for (const blob of embedded) {
                const candidate = walk(blob,target ? ['current_retail','currentRetail','formatted_current_price'] : ['currentPrice']);
                if (amount(candidate)) { value=amount(candidate); currency=walk(blob,['priceCurrency','currencyCode','currency']) || 'USD'; break; }
            }
            value = value || amount(attr(doc,target ? '[data-test="product-price"]' : '[data-testid="price-wrap"]'));
            currency = currency || 'USD';
        }
        if (!value) value = amount(attr(doc,'meta[property="product:price:amount"], meta[property="og:price:amount"], [itemprop="price"]','content') || attr(doc,'[itemprop="price"]'));
        currency = currency || attr(doc,'meta[property="product:price:currency"], meta[property="og:price:currency"], [itemprop="priceCurrency"]','content');
        if (!value || !currency) {
            for (const blob of embedded) {
                const price=embeddedPrice(blob);
                if(price){value=value||price.amount;currency=currency||price.currency;break;}
            }
        }
        const name = clean(linked && linked.name || attr(doc,'#productTitle, h1[itemprop="name"], h1') || meta.title);
        if (!name || !value || !/^[A-Z]{3}$/i.test(currency || '')) return null;
        const model = {kind:'product',name:name.slice(0,300),price:{amount:value,currency:currency.toUpperCase()},sellers:[]};
        if (linked) {
            const brand = linked.brand;
            if (brand) model.brand = clean(typeof brand === 'string' ? brand : brand.name);
            model.identifiers = {};
            ['gtin','gtin8','gtin12','gtin13','gtin14','mpn','sku'].forEach(k => { if(linked[k]) model.identifiers[k.startsWith('gtin')?'gtin':k]=String(linked[k]); });
            if (linked.productID || linked.sku) model.productId=String(linked.productID || linked.sku);
        }
        if(amazon) {
            const asin=/\/(?:dp|gp\/product|gp\/aw\/d)\/([A-Z0-9]{10})(?:[/?]|$)/i.exec(luna.parseURL(url).pathname);
            if(asin){model.productId=asin[1].toUpperCase();model.identifiers=Object.assign({},model.identifiers,{sku:model.productId});}
        }
        const image = linked && [].concat(linked.image || [])[0];
        const imageURL = absolute(typeof image==='object'?image.url:image || (amazon && (attr(doc,'#landingImage','data-old-hires') || attr(doc,'#landingImage','src'))) || meta.image,url);
        if (imageURL && /^https?:/i.test(imageURL)) model.imageURL=imageURL;
        model.sellers=offers.filter(o => o && o.url && amount(o.price) && o.priceCurrency).slice(0,20).map(o => ({url:absolute(o.url,url),price:{amount:amount(o.price),currency:o.priceCurrency}}));
        return model;
    }
    function tokens(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9-]+/g,' ').trim().split(/\s+/).filter(Boolean); }
    function matches(source, found) {
        const a=source.identifiers || {}, b=found.identifiers || {};
        for (const key of ['gtin','mpn']) {
            if (a[key] && b[key]) return String(a[key]).replace(/[^a-z0-9]/gi,'').toLowerCase() === String(b[key]).replace(/[^a-z0-9]/gi,'').toLowerCase();
        }
        if (source.brand && found.brand && clean(source.brand).toLowerCase()!==clean(found.brand).toLowerCase()) return false;
        const left=tokens(source.name), right=new Set(tokens(found.name));
        if (left.filter(t=>/\d/.test(t)).some(t=>!right.has(t))) return false;
        return left.length >= 3 && left.filter(t=>right.has(t)).length / left.length >= .85;
    }
    function candidates(model,url) {
        const host=luna.parseURL(url).hostname, source=sellerFor(host);
        const region=source && source.region || ({uk:'GB',au:'AU',ca:'CA',nz:'NZ',ie:'IE',in:'IN',sg:'SG',za:'ZA'})[host.split('.').pop()] || Object.keys(data.currencies).find(k=>data.currencies[k]===model.price.currency) || 'US';
        const words=' '+tokens(model.name).join(' ')+' ', categories=new Set(source ? source.categories.filter(c=>c!=='general'):[]);
        for(const [c,keywords] of Object.entries(data.categories)) if(keywords.some(k=>words.includes(' '+k+' ')||words.includes(' '+k+'s '))) categories.add(c);
        const gtin=model.identifiers && model.identifiers.gtin;
        return data.sellers.filter(s=>s.region===region&&!hostMatches(host,s.domain)&&!s.searchIsClientRendered)
            .map(s=>({seller:s,score:({1:30,2:18,3:8})[s.tier]+(s.verified?4:0)+(gtin&&s.acceptsGTIN?10:0)-(s.marketplace&&!gtin?8:0)+Math.min(24,s.categories.filter(c=>categories.has(c)).length*12)-(categories.size&&!s.categories.includes('general')&&!s.categories.some(c=>categories.has(c))?22:0)}))
            .filter(v=>categories.size || v.seller.categories.includes('general')).sort((a,b)=>b.score-a.score || a.seller.id.localeCompare(b.seller.id)).slice(0,6).map(v=>v.seller);
    }
    async function fetchPage(url) {
        try { const r=await luna.fetch({url,userAgent:'safari',timeout:5}); return r.ok&&typeof r.text==='string'?{doc:luna.html.parse(r.text,r.url||url),url:r.url||url}:null; } catch (_) { return null; }
    }
    async function compare(model,url) {
        const results=await Promise.all(candidates(model,url).map(async seller=>{
            const q=model.identifiers && model.identifiers.gtin && seller.acceptsGTIN ? model.identifiers.gtin : model.name;
            const search=seller.searchURL.replace('{query}',encodeURIComponent(q));
            const page=await fetchPage(search); if(!page)return null;
            const links=[...new Set(page.doc.querySelectorAll('a[href]').map(a=>a.absoluteURL('href')).filter(value=>{
                const u=luna.parseURL(value || '');
                return u && hostMatches(u.hostname,seller.domain) && !/\/(search|s|cart|login|account|category|collections)(\/|$)/i.test(u.pathname) && !/\.(js|json|css|png|jpg|svg)$/i.test(u.pathname) && u.pathname.split('/').filter(Boolean).length>0 && value!==search;
            }))].slice(0,3);
            for(const link of links) {
                const page=await fetchPage(link); if(!page)continue;
                const found=product(page.doc,page.url);
                if(found && found.price.currency===model.price.currency && matches(model,found))return {url:page.url,name:seller.name,price:found.price};
            }
            return null;
        }));
        const combined=(model.sellers || []).concat(results.filter(Boolean)), seen=new Set();
        model.sellers=combined.filter(s=>{const h=luna.parseURL(s.url).hostname.replace(/^www\./,'');if(seen.has(h))return false;seen.add(h);return true;}).slice(0,20);
        return model;
    }
    return {product,shoppingURL,compare,matches,candidates};
})();
// END BUNDLED SHOP HELPER
function interpret(html, url) {
    const doc = luna.html.parse(html, url);
    const item = LunaShop.product(doc, url);
    if (item) return item;
    const article = LunaWeb.article(html, url);
    if (!article) return null;
    delete article.text;
    return Object.assign({kind:'article',baseURL:url}, article);
}
luna.register({
    classify({url, page, context, intent}) {
        if (intent === 'transcribe') return false;
        const parsed = luna.parseURL(url);
        if (!parsed || excludedHost(parsed.hostname)) return false;
        if (/\.(pdf|epub|docx|rtf|md|txt)$/i.test(parsed.pathname)) return {kind:'article'};
        if (context === 'safari') {
            const result = page && interpret(page.html, url);
            return result ? {kind:result.kind} : false;
        }
        return {kind:'article'};
    },
    async ingest({url, page, intent, reason}) {
        if (intent === 'transcribe') return null;
        const parsed = luna.parseURL(url);
        const document = /\.((?:pdf|epub|docx|rtf|md|txt))$/i.exec(parsed.pathname);
        if (document) return {kind:'article',title:decodeURIComponent(parsed.pathname.split('/').pop()).slice(0,300),html:'',document:{url:url,type:document[1].toLowerCase()}};
        let html = page && page.url === url && page.html;
        if (!html) {
            const response = await luna.fetch({url:url,userAgent:'safari',timeout:15});
            if (!response.ok || typeof response.text !== 'string') return null;
            if (response.url && response.url !== url) {
                if (LunaWeb.isInterstitial(response.url)) return null;
                // Refresh/compare are owner-scoped operations, not pipeline redispatches.
                if (reason !== 'refresh' && reason !== 'compare' && reason !== 'reresolve') return {rewriteURL:response.url};
                url = response.url;
            }
            html = response.text;
        }
        const model = interpret(html, url);
        return model && model.kind === "product" && reason === "compare" ? await LunaShop.compare(model, url) : model;
    }
});
