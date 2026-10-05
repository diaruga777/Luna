// Publisher access strategy belongs to the plugin, including browser scripts.
const LunaAccess = (() => {
    const matches = (host, d) => host === d || host.endsWith('.' + d);
    const host = url => (luna.parseURL(url) || {}).hostname || '';
    const ruleFor = url => LunaAccessRules.rules.find(r => matches(host(url),r.domain));
    const ampHosts = ['theaustralian.com.au','adelaidenow.com.au','cairnspost.com.au','codesports.com.au','couriermail.com.au','dailytelegraph.com.au','geelongadvertiser.com.au','goldcoastbulletin.com.au','heraldsun.com.au','ntnews.com.au','thechronicle.com.au','themercury.com.au','townsvillebulletin.com.au','weeklytimesnow.com.au'];
    const identities = [
        'XaiImageApiFetch/1.0', 'Mozilla/5.0 (compatible; Google-InspectionTool/1.0)',
        'googlebot', 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Claude-User/1.0; +Claude-User@anthropic.com)',
        'OpenAI File Downloader', 'bingbot'
    ];
    function canProbe(url) {
        return !/(^|\.)(x.com|twitter.com|youtube.com|youtu.be|reddit.com|redd.it|instagram.com|tiktok.com|facebook.com|bsky.app)$/.test(host(url));
    }
    function eligible(url,html) {
        if (/(^|\.)(x.com|twitter.com|youtube.com|youtu.be|reddit.com|instagram.com|tiktok.com|facebook.com|bsky.app)$/.test(host(url)))return false;
        const u=luna.parseURL(url); if(!u||u.pathname==='/'||/\.(pdf|epub|docx|mp4|mp3|zip)$/i.test(u.pathname))return false;
        if (html && /["']@type["']\s*:\s*["']Product["']/.test(html)) return false;
        return !!ruleFor(url) || /isAccessibleForFree["']?\s*:\s*false|subscribe to (read|continue)|subscription required|paywall|meteredContent|already a subscriber/i.test(html || '');
    }
    function prepare(html) {
        // Machine-marked AMP gate furniture is never part of the article.
        return html.replace(/<([\w-]+)\b[^>]*subscriptions-section=["'](?!content["'])[^"']*["'][^>]*>[\s\S]*?<\/\1>/gi,'')
            .replace(/<\/?amp-img\b/gi, m=>m.replace('amp-img','img'));
    }
    function article(html,url) {
        const value=LunaWeb.article(prepare(html),url);
        if(!value)return null;
        delete value.text;
        return Object.assign({kind:'article',baseURL:url},value);
    }
    async function fetchArticle(url,original,options={}) {
        try {const r=await luna.fetch(Object.assign({url,timeout:5,cookies:'none'},options));return r.ok&&typeof r.text==='string'&&!LunaWeb.isInterstitial(r.url||url)?article(r.text,original):null;}catch(_){return null;}
    }
    function blockers(url,rule) {
        const patterns=[...(rule && rule.blockRegex || [])];
        for(const r of LunaAccessRules.generalBlockers || []) if(!(r.excludedDomains || []).some(d=>matches(host(url),d)))patterns.push(r.blockRegex);
        // A plugin selects the patterns; the host merely compiles WK's syntax.
        return patterns.map(p=>p.replace(/\\\//g,'/').replace(/\\d/g,'[0-9]').replace(/\(\?:/g,'(')).filter(p=>!/[{}]|\(\?|\\[bwsd1-9]|\)[?*+]/.test(p)).slice(0,100);
    }
    function cleanup(url,rule) {
        const bespoke=LunaAccessCleanup.find(r=>r.domains.some(d=>matches(host(url),d)));
        const setup='try { '+(rule && rule.clearLocalStorage?'localStorage.clear();sessionStorage.clear();':'')+' } catch(_) {}';
        const generic=`(() => {
            const run=()=>{document.querySelectorAll('[subscriptions-section]:not([subscriptions-section="content"]), [class*="paywall-overlay"], [id*="paywall-overlay"]').forEach(n=>n.remove());
            document.querySelectorAll('[subscriptions-section="content"]').forEach(n=>{n.removeAttribute('subscriptions-section');n.style.display='block';});};run();setTimeout(run,1000);
        })();`;
        return setup+generic+(bespoke ? bespoke.js : '');
    }
    async function archived(url,oldest) {
        try {
            const query='https://web.archive.org/cdx/search/cdx?url='+encodeURIComponent(url)+'&output=json&filter=statuscode:200&filter=mimetype:text/html&collapse=timestamp:6&limit=1'+(oldest?'':'&sort=reverse');
            const r=await luna.fetch({url:query,timeout:4});
            let rows;try{rows=JSON.parse(r.text);}catch(_){rows=null;}
            if(Array.isArray(rows)&&rows.length>1){const header=rows[0],row=rows[1],timestamp=row[header.indexOf('timestamp')];if(/^\d{14}$/.test(timestamp))return await fetchArticle('https://web.archive.org/web/'+timestamp+'id_/'+url,url);}
            if(!oldest){const a=await luna.fetch({url:'https://archive.org/wayback/available?url='+encodeURIComponent(url),timeout:4});const v=JSON.parse(a.text);const snap=v.archived_snapshots&&v.archived_snapshots.closest;if(snap&&snap.available&&/^\d{14}$/.test(snap.timestamp))return await fetchArticle('https://web.archive.org/web/'+snap.timestamp+'id_/'+url,url);}
        }catch(_){}
        return null;
    }
    const detect=`(() => {
        if (/captcha|verify you are human|checking your browser/i.test(document.title)) return 'challenge';
        const article=document.querySelector('article,[itemprop="articleBody"],main');
        const text=article?article.innerText:'';
        return text.length>1200&&!/subscribe to (continue|read)|already a subscriber/i.test(text)?'done':'wait';
    })()`;
    async function resolve({url,page,reason,context,saveId}) {
        let html=page&&page.url===url&&page.html;
        if(!html){try{const r=await luna.fetch({url,userAgent:'safari',timeout:5});html=r.text;}catch(_){}}
        const readable=html&&article(html,url); if(readable)return readable;
        if(!eligible(url,html))return null;
        const rule=ruleFor(url);
        const requests=[];
        if(ampHosts.some(d=>matches(host(url),d))&&!/[?&]amp(?:[=&]|$)/.test(url))requests.push(fetchArticle(url.split('#')[0]+(url.includes('?')?'&':'?')+'amp',url));
        if(rule)requests.push(fetchArticle(url,url,{userAgent:rule.useragentCustom||rule.useragent||'safari',headers:rule.refererCustom||rule.referer?{Referer:rule.refererCustom||'https://www.google.com/'}:{},cookies:rule.allowCookies?'shared':'none'}));
        const declined=/haaretz|themarker|nbcnews|telegraph/.test(host(url))?[1,2,5]:host(url)==='leparisien.fr'?[0,1,2,4,5]:host(url)==='law.com'?[0,3,4]:[];
        identities.filter((_,i)=>!declined.includes(i)).slice(0,4).forEach(userAgent=>requests.push(fetchArticle(url,url,{userAgent})));
        const results=await Promise.all(requests);const found=results.find(Boolean);if(found)return found;
        const published=html&&LunaWeb.meta(luna.html.parse(html,url)).published;
        const recent=published&&Date.now()-Date.parse(published)<180*86400000;
        const snapshots=await Promise.all([archived(url,false),recent?Promise.resolve(null):archived(url,true)]);
        if(snapshots.some(Boolean))return snapshots.find(Boolean);
        // Background price/media work and speculative reads have no browser save scope.
        if((!saveId && context!=='safari') || reason==='refresh'||reason==='compare'||reason==='reresolve')return null;
        const live=await luna.browser.open({url,saveId,cookies:rule&&rule.allowCookies?'persistent':'ephemeral',
            userAgent:rule&&rule.useragentCustom,title:'Open article',detect,
            scripts:[cleanup(url,rule)],blockURLs:blockers(url,rule),timeout:90});
        const liveArticle=live&&article(live.html,url);if(liveArticle)return liveArticle;
        const snapshot=await luna.browser.open({url:'https://archive.ph/newest/'+url,saveId,title:'Find archived article',detect,timeout:180});
        return snapshot?article(snapshot.html,url):null;
    }
    return {resolve,eligible,article,blockers,cleanup,canProbe};
})();
