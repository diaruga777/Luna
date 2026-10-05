/* luna-plugin
{"id":"app.luna.url-rewrites","name":"Shared link destinations","version":"1.0.1","api":1,
 "description":"Unwraps news, retailer and social redirect links before redispatching to the destination plugin.",
 "produces":["article"],"match":{"any":true},"priority":1000,"capabilities":["fetch","html"]}
*/
const shorteners = ['flip.it','trib.al','t.co','bit.ly','buff.ly','apple.co','nyti.ms','wapo.st','on.ft.com','econ.st','reut.rs','cnn.it','bbc.in','nbcnews.to','abcn.ws','cbsn.ws','links.message.bloomberg.com','bloom.bg','amzn.to','amzn.asia','a.co','share.google'];
function hasHost(host, names) { return names.some(function (n) { return host === n || host.endsWith('.' + n); }); }
const interstitialSegments = new Set(['subscribe','subscribes','subscription','subscriptions','paywall','signin','sign-in','login','log-in','register','checkout','check_cookie.html']);
const targetParameters = ['dest','destination','returnurl','return_url','return','redirect','redirecturl','redirect_uri','url','next','targeturl'];
function interstitial(p) { return p.pathname.toLowerCase().split('/').some(part => interstitialSegments.has(part)); }
function webTarget(value) {
    const p = value && luna.parseURL(value);
    return p && /^https?:$/.test(p.protocol) ? p : null;
}
function sameSite(a,b) {
    a=a.replace(/^www\./,''); b=b.replace(/^www\./,'');
    return a===b || a.endsWith('.'+b) || b.endsWith('.'+a);
}
function destination(url) {
    const p = luna.parseURL(url); if (!p) return null;
    if (hasHost(p.hostname,['facebook.com']) && p.pathname.toLowerCase() === '/l.php') {
        const target=webTarget(p.searchParams.get('u'));
        return target && !hasHost(target.hostname,['facebook.com','fb.com']) ? target.href : null;
    }
    if (interstitial(p)) {
        // Query keys are case-insensitive here, matching publisher share links.
        const pairs=p.search.slice(1).split('&').map(pair => {
            const at=pair.indexOf('=');
            try { return [decodeURIComponent(at<0?pair:pair.slice(0,at)).toLowerCase(),decodeURIComponent((at<0?'':pair.slice(at+1)).replace(/\+/g,' '))]; }
            catch (_) { return []; }
        });
        for (const key of targetParameters) {
            const pair=pairs.find(pair=>pair[0]===key), target=webTarget(pair && pair[1]);
            if(target && sameSite(target.hostname,p.hostname) && !interstitial(target))return target.href;
        }
    }
    return null;
}
function special(p) { return hasHost(p.hostname,shorteners.concat(['apple.news','stocks.apple.com','news.google.com','news.url.google.com'])); }
luna.register({
    classify({url}) { const p = luna.parseURL(url); return p && (destination(url) || special(p)) ? {kind:'article'} : false; },
    async ingest({url}) {
        const direct = destination(url); if (direct) return {rewriteURL:direct};
        const p = luna.parseURL(url);
        if (!p || !special(p)) return null;
        if (hasHost(p.hostname,['news.google.com','news.url.google.com'])) {
            const match = /\/(?:articles|read)\/([^/?]+)/.exec(p.pathname);
            if (!match) return null;
            const id = match[1];
            try {
                const base64 = id.replace(/-/g,'+').replace(/_/g,'/');
                const decoded = luna.bytes.utf8Decode(luna.bytes.fromBase64(base64.padEnd(Math.ceil(base64.length / 4) * 4, '=')));
                const embedded = /https?:\/\/[^\x00-\x20\x7f-\uffff"<>\\]+/.exec(decoded);
                if (embedded) return {rewriteURL:embedded[0]};
            } catch (_) {}
            const page = await luna.fetch({url:'https://news.google.com/rss/articles/' + id,timeout:12});
            const signature = /data-n-a-sg="([^"]+)"/.exec(page.text || '');
            const timestamp = /data-n-a-ts="([^"]+)"/.exec(page.text || '');
            if (!signature || !timestamp) return null;
            const inner = '["garturlreq",[["X","X",["X","X"],null,null,1,1,"US:en",null,1,null,null,null,null,0,1],"X","X",1,[1,1,1],1,1,null,0,0,null,0],'+JSON.stringify(id)+','+timestamp[1]+','+JSON.stringify(signature[1])+']';
            const result = await luna.fetch({url:'https://news.google.com/_/DotsSplashUi/data/batchexecute',method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded;charset=utf-8'},body:'f.req='+encodeURIComponent(JSON.stringify([[['Fbv4je',inner]]])),timeout:12});
            const target = /garturlres\\?",\\?"(https?:[^"\\]+)/.exec(result.text || '');
            return target ? {rewriteURL:target[1]} : null;
        }
        const response = await luna.fetch({url:url,userAgent:'safari',redirect:'follow',timeout:12});
        if (hasHost(p.hostname,['apple.news','stocks.apple.com'])) {
            const match = /redirectToUrlAfterTimeout\(\s*["']([^"']+)/.exec(response.text || '');
            if (match) return {rewriteURL:decodeURIComponent(match[1])};
        }
        return response.url && response.url !== url ? {rewriteURL:response.url} : null;
    }
});
