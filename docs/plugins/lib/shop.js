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
        const offers = linked ? [].concat(linked.offers || []).flatMap(o => o.offers ? [].concat(o.offers) : [o]) : [];
        let offer = offers.find(o => o && amount(o.price)) || {};
        let value = amount(offer.price), currency = offer.priceCurrency;
        const embedded = luna.html.jsonScripts(doc,'application/json');
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
        const image = linked && [].concat(linked.image || [])[0];
        const imageURL = absolute(typeof image==='object'?image.url:image || meta.image,url);
        if (imageURL) model.imageURL=imageURL;
        model.sellers=offers.filter(o => o.url && amount(o.price) && o.priceCurrency).slice(0,20).map(o => ({url:absolute(o.url,url),price:{amount:amount(o.price),currency:o.priceCurrency}}));
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
