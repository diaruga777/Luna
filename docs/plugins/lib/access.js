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
    function prepare(html,url) {
        const snapshot=luna.html.parse(html,url);
        const content=snapshot.querySelector('#CONTENT');
        if(content) html='<html><head>'+(snapshot.head?snapshot.head.innerHTML:'')+
            '</head><body><article>'+content.innerHTML+'</article></body></html>';
        html=LunaNewYorker.prepare(html,url);
        if(matches(host(url),'livemint.com')) {
            // Mint labels the continuation's editorial wrappers paywall-slot.
            // Generic noise stripping would discard all but the opening paragraph;
            // its JSON-LD articleBody is also just that teaser. Select the real
            // paragraphs inside the story before removing subscription furniture.
            const doc=luna.html.parse(html,url);
            const paragraphs=doc.querySelectorAll('#mainArea .storyParagraph');
            if(paragraphs.length) html='<html><head>'+(doc.head?doc.head.innerHTML:'')+
                '</head><body><article>'+paragraphs.map(n=>'<div>'+n.innerHTML+'</div>').join('\n')+
                '</article></body></html>';
        }
        if(matches(host(url),'thedailybeast.com')) {
            const doc=luna.html.parse(html,url);
            const content=doc.querySelector('article#article-content');
            if(content) {
                // Astro marks the actual continuation paragraphs/images as
                // tdb-paywall. They are content, not subscription furniture.
                // Select editorial blocks before generic gate/noise detection;
                // recirculation cards and subscription offers are siblings.
                const types=['text','image','heading','list','blockquote'];
                const blocks=content.children.filter(n=>types.includes(n.getAttribute('data-block-type')));
                if(blocks.length) html='<html><head>'+(doc.head?doc.head.innerHTML:'')+'</head><body><article>'+
                    blocks.map(n=>'<'+n.tagName+'>'+n.innerHTML+'</'+n.tagName+'>').join('\n')+
                    '</article></body></html>';
            }
        }
        // Machine-marked AMP gate furniture is never part of the article.
        return html.replace(/<([\w-]+)\b[^>]*subscriptions-section=["'](?!content["'])[^"']*["'][^>]*>[\s\S]*?<\/\1>/gi,'')
            .replace(/<\/?amp-img\b/gi, m=>m.replace('amp-img','img'));
    }
    function article(html,url) {
        const value=LunaWeb.article(prepare(html,url),url);
        if(!value)return null;
        delete value.text;
        return Object.assign({kind:'article',baseURL:url},value);
    }
    async function fetchArticle(url,original,options={}) {
        try {const r=await luna.fetch(Object.assign({url,timeout:5,cookies:'none'},options));return r.ok&&typeof r.text==='string'&&!LunaWeb.isInterstitial(r.url||url)?article(r.text,original):null;}catch(_){return null;}
    }
    // A readable response settles the search immediately. Waiting for every
    // probe can hold a complete article behind a slow or trickling response.
    // Declines and failures only finish the search after all probes decline.
    function firstReadable(probes) {
        return new Promise(resolve => {
            let remaining=probes.length;
            if(!remaining){resolve(null);return;}
            probes.forEach(probe => Promise.resolve(probe).catch(()=>null).then(value => {
                if(value)resolve(value);
                if(--remaining===0)resolve(null);
            }));
        });
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
    // Mint republishes WSJ reporting with a canonical link back to the original.
    // Use the publisher's own index, then verify that identity on the fetched
    // page. A matching headline alone must never substitute a different story.
    async function syndicatedWSJ(url) {
        if(!matches(host(url),'wsj.com'))return null;
        const path=(luna.parseURL(url)||{}).pathname||'';
        const slug=path.split('/').pop().replace(/-[a-f0-9]{8}$/, '');
        if(slug.length<20)return null;
        try {
            const index=await luna.fetch({url:'https://www.livemint.com/wsj',timeout:5,cookies:'none'});
            if(!index.ok)return null;
            const doc=luna.html.parse(index.text,'https://www.livemint.com/wsj');
            const candidates=[...new Set(doc.querySelectorAll('a[href]').map(a=>a.absoluteURL('href')))]
                .filter(u=>u&&host(u)==='www.livemint.com'&&((luna.parseURL(u)||{}).pathname||'').split('/').pop().startsWith(slug+'-')).slice(0,3);
            return await firstReadable(candidates.map(async candidate=>{
                const response=await luna.fetch({url:candidate,timeout:5,cookies:'none'});
                if(!response.ok)return null;
                const page=luna.html.parse(response.text,candidate);
                const canonical=page.querySelector('link[rel="canonical"]');
                const source=canonical&&luna.parseURL(canonical.absoluteURL('href'));
                if(!source||!matches(source.hostname,'wsj.com')||source.pathname!==path)return null;
                const value=article(response.text,candidate);
                if(!value)return null;
                // Resolve relative media against the copy, retaining the saved WSJ URL.
                value.baseURL=candidate;
                return value;
            }));
        }catch(_){return null;}
    }
    async function archiveSnapshotURL(url) {
        try {
            const r=await luna.fetch({url:'https://archive.is/timemap/'+url,timeout:4});
            if(!r.ok)return null;
            const entries=String(r.text).match(/<[^>]+>[^<]*/g)||[];
            let last=null,explicit=null;
            for(const entry of entries) {
                const m=entry.match(/^<([^>]+)>([\s\S]*)$/);
                if(!m||!/rel\s*=\s*"[^"]*memento/i.test(m[2]))continue;
                const parsed=luna.parseURL(m[1]);
                if(!parsed||!['http:','https:'].includes(parsed.protocol)||!/^archive\.(is|ph|today|li|fo|md|vn)$/.test(parsed.hostname))continue;
                last=m[1].replace(/^http:/,'https:');if(/last memento/i.test(m[2]))explicit=last;
            }
            return explicit||last;
        }catch(_){return null;}
    }
    // Content wins over unrelated ad CAPTCHA widgets. Check every root: WSJ
    // snapshots often put teaser <article>s before the actual article body.
    const detect=`(() => {
        const body=document.body?document.body.innerText:'';
        const roots=Array.from(document.querySelectorAll('article,[itemprop="articleBody"],[class*="article-body"],#CONTENT,main'));
        if(roots.some(n=>n.innerText.length>1200&&!/subscribe to (continue|read)|already a subscriber/i.test(n.innerText)))return 'done';
        if(document.querySelector('#g-recaptcha,.g-recaptcha,[data-sitekey],.cf-turnstile,#challenge-form,iframe[src*="captcha"],iframe[src*="challenges.cloudflare.com"]') ||
           /captcha|verify (you are|you're)( a)? human|checking your browser|just a moment/i.test(document.title) ||
           /why do i have to complete a captcha|verify (you are|you're)( a)? human|checking your browser|needs to review the security/i.test(body))return 'challenge';
        if(/-32602|invalid interception ?id/i.test(body) ||
           (body.length<4000&&/enable (js|javascript)/i.test(body)&&/ad ?blocker/i.test(body)))return 'error';
        // A publisher login/paywall requires the person, too. It cannot make
        // progress while hidden under a spinner.
        if(/subscribe to (continue|read)|already a subscriber/i.test(body))return 'challenge';
        return 'wait';
    })()`;
    function archiveDetect(url,snapshotURL) {
        return `(() => {
            // Establish the archive session through its homepage first. Direct
            // newest/snapshot loads can get a permanent "enable JS" gate in WK.
            const input=document.querySelector('input[name="url"]');
            if((location.pathname==='/'||location.pathname==='')&&input&&input.form){
                if(!window.__lunaArchiveSubmitted){
                    window.__lunaArchiveSubmitted=true;
                    const snapshot=${JSON.stringify(snapshotURL)};
                    if(snapshot)location.href=snapshot;
                    else {input.value=${JSON.stringify(url)};input.form.submit();}
                }
                return 'wait';
            }
            return (${detect});
        })()`;
    }
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
        const found=await firstReadable(requests);if(found)return found;
        const published=html&&LunaWeb.meta(luna.html.parse(html,url)).published;
        const recent=published&&Date.now()-Date.parse(published)<180*86400000;
        let snapshotURL=null;
        const today=archiveSnapshotURL(url).then(async value=>{
            snapshotURL=value;return value?await fetchArticle(value,url):null;
        });
        const snapshotArticle=await firstReadable([syndicatedWSJ(url),archived(url,false),recent?Promise.resolve(null):archived(url,true),today]);
        if(snapshotArticle)return snapshotArticle;
        // Background price/media work and speculative reads have no browser save scope.
        if((!saveId && context!=='safari') || reason==='refresh'||reason==='compare'||reason==='reresolve')return null;
        // WSJ's server-side wall cannot be removed with a live-page cleanup.
        // Go straight to the archive after silent probes rather than hiding it
        // for a ninety-second live wait that can never recover the body.
        if(!matches(host(url),'wsj.com')) {
            const live=await luna.browser.open({url,saveId,cookies:rule&&rule.allowCookies?'persistent':'ephemeral',
                userAgent:rule&&rule.useragentCustom,title:'Open article',detect,
                scripts:[cleanup(url,rule)],blockURLs:blockers(url,rule),timeout:90});
            const liveArticle=live&&article(live.html,url);if(liveArticle)return liveArticle;
        }
        const snapshot=await luna.browser.open({url:'https://archive.is/',saveId,title:'Find archived article',detect:archiveDetect(url,snapshotURL),timeout:180});
        return snapshot?article(snapshot.html,url):null;
    }
    return {resolve,eligible,article,blockers,cleanup,canProbe};
})();
