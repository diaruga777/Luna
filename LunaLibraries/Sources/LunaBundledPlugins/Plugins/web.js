/* luna-plugin
{"id":"app.luna.web","name":"Web articles and products","version":"1.0.0","api":1,
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

    var text = { price: textPrice, date: textDate, clean: textClean };


    const noise = /(?:^|[\s_-])(comment|related|recirc|recommend|newsletter|subscribe|paywall|advert|social|share|menu|nav|footer|cookie|promo|breadcrumb)(?:$|[\s_-])/i;
    function excluded(node) {
        if (!node) return false;
        if (["SCRIPT", "STYLE", "NAV", "FOOTER", "ASIDE", "FORM", "BUTTON", "NOSCRIPT"].indexOf(node.tagName) >= 0) return true;
        return node.hasAttribute('hidden') || node.getAttribute('aria-hidden') === 'true'
            || noise.test((node.getAttribute('class') || '') + ' ' + (node.getAttribute('id') || ''));
    }
    function visible(node, root) {
        for (let n = node; n; n = n.parentElement) {
            if (excluded(n)) return false;
            if (n.outerHTML === root.outerHTML) break;
        }
        return true;
    }
    function article(source, base) {
        const doc = luna.html.parse(source, base);
        const meta = htmlMeta(doc);
        const linked = jsonLD(doc).find(function (entry) {
            return entry && /Article|BlogPosting/.test(String(entry['@type']));
        });
        // Select a single body; do not concatenate unrelated cards and replies.
        const candidates = doc.querySelectorAll('article, main, [role="main"], [itemprop="articleBody"], .article-body, .entry-content, .post-content');
        if (candidates.length === 0 && doc.body) candidates.push(doc.body);
        let winner = null, best = 0;
        candidates.forEach(function (candidate) {
            if (excluded(candidate)) return;
            const paragraphs = candidate.querySelectorAll('p').filter(function (p) { return visible(p, candidate); });
            const textLength = paragraphs.reduce(function (n, p) { return n + p.textContent.length; }, 0);
            const linkedLength = candidate.querySelectorAll('a').reduce(function (n, a) { return n + a.textContent.length; }, 0);
            const score = textLength - linkedLength * 1.5;
            if (score > best) { best = score; winner = candidate; }
        });
        let html = '', body = '';
        if (winner && best >= 300) {
            const nodes = winner.querySelectorAll('p, h2, h3, h4, li, blockquote, figure, img');
            const selected = [];
            nodes.forEach(function (node) {
                if (!visible(node, winner)) return;
                // Keep only the outer selected block (figure owns its image,
                // blockquote its paragraph). DOM handles have no stable identity.
                if (selected.some(function (parent) { return parent.outerHTML.indexOf(node.outerHTML) >= 0; })) return;
                selected.push(node);
            });
            html = selected.map(function (n) { return n.outerHTML; }).join('\n');
            body = selected.map(function (n) { return n.textContent; }).join('\n').trim();
        }
        if (linked && typeof linked.articleBody === 'string' && linked.articleBody.length > body.length) {
            body = linked.articleBody;
            html = body.split(/\n+/).filter(Boolean).map(function (p) { return '<p>' + escape(p) + '</p>'; }).join('');
        }
        if (body.length < 300 || !html) return null;
        // Visible subscription teasers must not be saved as a complete article.
        const locked = /subscribe to (continue|read)|already a subscriber|unlock this article|sign in to continue/i.test(body);
        if (locked || (linked && linked.isAccessibleForFree === false && body.length < 1200)) return null;
        const heading = winner && winner.querySelector('h1');
        const result = {title: meta.title || (heading && heading.textContent) || base, html: html, text: body};
        if (meta.author) result.author = meta.author;
        if (meta.image) result.leadImageURL = meta.image;
        if (meta.description) result.excerpt = meta.description.slice(0, 1000);
        if (meta.published) result.publishedAt = textDate(meta.published) || undefined;
        return result;
    }
    return {article: article, meta: htmlMeta, jsonLD: jsonLD, price: textPrice,
        date: textDate, clean: textClean, escape: escape, absoluteURL: absoluteURL};
})();
// END BUNDLED WEB HELPER

function excludedHost(host) {
    // Social feeds must never become articles merely because replies are long.
    return /(^|\.)(x\.com|twitter\.com|reddit\.com|redd\.it|instagram\.com|facebook\.com|tiktok\.com|youtube\.com|youtu\.be|bsky\.app)$/.test(host);
}
function product(doc, url) {
    const entries = LunaWeb.jsonLD(doc);
    const found = entries.find(function (v) { return v && [].concat(v['@type'] || []).includes('Product'); });
    const meta = LunaWeb.meta(doc);
    function attr(selector, name) { const n = doc.querySelector(selector); return n && (name ? n.getAttribute(name) : n.textContent); }
    const parsed = luna.parseURL(url);
    const host = parsed.hostname;
    const offers = found ? [].concat(found.offers || []) : [];
    let offer = offers.find(function (o) { return o && o.price !== undefined; }) || offers[0] || {};
    if (offer.offers) offer = [].concat(offer.offers).find(function (o) { return o.price !== undefined; }) || offer;
    let price = offer.price !== undefined ? {amount:String(offer.price),currency:offer.priceCurrency} : null;
    if (!price) {
        const amount = attr('meta[property="product:price:amount"], meta[property="og:price:amount"], [itemprop="price"]', 'content');
        const currency = attr('meta[property="product:price:currency"], meta[property="og:price:currency"], [itemprop="priceCurrency"]', 'content');
        if (amount) price = {amount:amount,currency:currency};
    }
    if (!price && /(^|\.)amazon\./.test(host)) {
        const value = attr('#corePrice_feature_div .a-price .a-offscreen, #corePriceDisplay_desktop_feature_div .a-price .a-offscreen, #priceblock_ourprice, #priceblock_dealprice');
        if (value) price = LunaWeb.price(value);
    }
    if (!price && /(^|\.)target\.com$/.test(host)) {
        const value = attr('[data-test="product-price"]');
        if (value) price = LunaWeb.price(value);
    }
    if (!price && /(^|\.)walmart\.com$/.test(host)) {
        const value = attr('[itemprop="price"]', 'content') || attr('[data-testid="price-wrap"]');
        if (value) price = LunaWeb.price(value);
    }
    const name = found && found.name || attr('#productTitle, [itemprop="name"], h1') || meta.title;
    if (!name || !price || !/^\d+(?:\.\d+)?$/.test(price.amount) || !price.currency) return null;
    const model = {kind:'product',name:LunaWeb.clean(name).slice(0,300),price:price};
    const brand = found && found.brand;
    if (brand) model.brand = (typeof brand === 'string' ? brand : brand.name);
    const image = found && [].concat(found.image || [])[0];
    if (image || meta.image) model.imageURL = typeof image === 'object' ? image.url : image || meta.image;
    if (found) {
        model.identifiers = {};
        ['gtin','gtin8','gtin12','gtin13','gtin14','mpn','sku'].forEach(function (key) {
            if (found[key]) model.identifiers[key.startsWith('gtin') ? 'gtin' : key] = String(found[key]);
        });
        if (found.productID || found.sku) model.productId = String(found.productID || found.sku);
    }
    model.sellers = offers.filter(function (o) { return o.url && o.price !== undefined && o.priceCurrency; }).slice(0,20).map(function (o) {
        return {url:o.url,name:o.seller && o.seller.name,price:{amount:String(o.price),currency:o.priceCurrency}};
    });
    return model;
}
function interpret(html, url) {
    const doc = luna.html.parse(html, url);
    const item = product(doc, url);
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
    async ingest({url, page, intent}) {
        if (intent === 'transcribe') return null;
        const parsed = luna.parseURL(url);
        const document = /\.((?:pdf|epub|docx|rtf|md|txt))$/i.exec(parsed.pathname);
        if (document) return {kind:'article',title:decodeURIComponent(parsed.pathname.split('/').pop()).slice(0,300),html:'',document:{url:url,type:document[1].toLowerCase()}};
        let html = page && page.url === url && page.html;
        if (!html) {
            const response = await luna.fetch({url:url,userAgent:'safari',timeout:15});
            if (!response.ok || typeof response.text !== 'string') return null;
            if (response.url && response.url !== url) return {rewriteURL:response.url};
            html = response.text;
        }
        return interpret(html, url);
    }
});
