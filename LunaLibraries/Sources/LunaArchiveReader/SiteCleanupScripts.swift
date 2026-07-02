//
//  SiteCleanupScripts.swift
//  ReaderKit
//

import Foundation
import WebKit

/// Per-site bespoke DOM-cleanup snippets injected by the browser tier (alongside the
/// generic `PaywallUnlockRules` cleanup) when the paywall-unlock toggle is on. Each is
/// a self-contained JavaScript IIFE (no extension APIs, no cross-origin fetch beyond
/// the page's own origin) that reveals a specific site's article — removing that site's
/// overlay, stripping the classes/attributes it uses to clamp the body, reconstructing
/// the body from embedded JSON (`__NEXT_DATA__` / Fusion / Redux state), un-lazying
/// images, etc. Only the iOS-feasible DOM operations are ported; site logic whose sole
/// mechanism is a cross-origin/extension fetch is omitted (the generic cleanup + the
/// content blocker still apply, and archive.today remains the terminal fallback).
///
/// Covers the top news platforms of English-speaking countries (the upstream per-site
/// logic ships no continental-European sites in the shared script). Extend by adding a
/// `domain: snippet` entry.
public enum SiteCleanupScripts {

    /// The bespoke cleanup snippet for `url`'s host (exact or registrable-suffix
    /// match), or nil when the site has no per-site snippet.
    public static func script(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if let snippet = byDomain[host] { return snippet }
        var labels = host.split(separator: ".").map(String.init)
        while labels.count > 2 {
            labels.removeFirst()
            if let snippet = byDomain[labels.joined(separator: ".")] { return snippet }
        }
        return nil
    }

    /// A `WKUserScript` (documentEnd, main frame) for `url`, or nil.
    public static func userScript(for url: URL) -> WKUserScript? {
        guard let source = script(for: url) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Number of sites with a bespoke snippet (diagnostics/tests).
    public static var count: Int { byDomain.count }

    /// Wraps a CSS rule in the standard "inject a display:none stylesheet" IIFE — the
    /// most common per-site reveal (hide the overlay/ads so the body beneath shows).
    private static func hide(_ css: String) -> String {
        #"(function(){try{var s=document.createElement('style');s.textContent='"#
            + css
            + #"';(document.head||document.documentElement).appendChild(s);}catch(e){}})();"#
    }

    /// domain → self-contained cleanup IIFE.
    static let byDomain: [String: String] = {
        var m: [String: String] = [:]

        // --- Simple overlay/ad hides (body already client-side; reveal by hiding) ---
        m["nytimes.com"] = hide(##"#top-wrapper,#bottom-wrapper,#dock-container,div[class$="ad-wrapper"],div[class^="adunit_"],div[data-testid^="Dropzone-"]"##)
        m["washingtonpost.com"] = hide(##"wp-ad-wrapper,div[data-qa$="-ad"],div[data-component="Ad"],div[data-qa="outbrain"],div.PJLV-ifmxCWD-css"##)
        m["businessinsider.com"] = hide("div.masthead-ad,div.l-ad,div.in-post-sticky,aside.has-video-ad,div.ad-callout-wrapper")
        m["theatlantic.com"] = hide(##"aside#paywall,div[class^="LostInventoryMessage_"]"##)
        m["economist.com"] = hide(##"div[class*="adComponent"]"##)
        m["politico.com"] = hide(##"div.ad,div[class^="leaderboardAd"]"##)
        m["newstatesman.com"] = hide("div.ad")
        m["telegraph.co.uk"] = hide(##"[class^="subwall"],.advert,.commercial-unit"##)
        m["aftenposten.no"] = hide(##"div[class^="advertory-"]"##)
        m["wsj.com"] = hide(##".snippet-promotion,div[id*="-snippet-overlay"],div.wsj-ad,div.adWrapper,div#cx-article-cover-overlay,div#dianomi-module"##)

        // Nine/Fairfax (AU) — shared branch, ad hide only.
        let nine = hide(##"div[data-testid="ad"]"##)
        for d in ["smh.com.au", "theage.com.au", "brisbanetimes.com.au", "watoday.com.au"] { m[d] = nine }

        // Condé Nast — reveal maps, hide the paywall bar + ads.
        let conde = ##"(function(){try{document.querySelectorAll('div.map_wrapper').forEach(function(e){e.style.visibility='visible';});var s=document.createElement('style');s.textContent='div.ad,aside.paywall-bar,div[class^="MessageBannerWrapper-"],div.ad-stickyhero,div.ad_wrapper{display:none!important}';(document.head||document.documentElement).appendChild(s);}catch(e){}})();"##
        for d in ["newyorker.com", "wired.com", "vanityfair.com", "gq.com", "vogue.com",
                  "bonappetit.com", "cntraveler.com", "architecturaldigest.com",
                  "epicurious.com", "pitchfork.com"] { m[d] = conde }

        // The Times (UK) — hide paywall footer/takeover + ads, restore scroll, un-lazy images.
        let times = ##"(function(){try{var s=document.createElement('style');s.textContent='div#paywall-portal-page-footer,div#paywall-portal-article-footer,div#paywall-takeover,div.channel-header-ad,div[id^="advert-"],div[class*="InlineAdWrapper"],div[id^="ad-article-inline"]{display:none!important} html,body{overflow:auto!important;height:auto!important}';(document.head||document.documentElement).appendChild(s);document.querySelectorAll('article img[src^="data:image/"][currentsourceurl]').forEach(function(e){e.src=e.getAttribute('currentsourceurl');});}catch(e){}})();"##
        m["thetimes.co.uk"] = times
        m["thetimes.com"] = times

        // LA Times — remove the "subscribers" infobox promo + hide ads.
        m["latimes.com"] = ##"(function(){try{document.querySelectorAll('div.infobox > p.infobox-title').forEach(function(p){if(/subscribers/i.test(p.textContent)&&p.parentNode)p.parentNode.remove();});var s=document.createElement('style');s.textContent='div.google-dfp-ad-wrapper,div.revcontent{display:none!important}';(document.head||document.documentElement).appendChild(s);}catch(e){}})();"##

        // The Globe and Mail — un-lazy images, restore TTS-audio/video from in-page
        // Fusion metadata JSON, hide ads.
        m["theglobeandmail.com"] = ##"(function(){try{document.querySelectorAll('img[src^="data:image/"][data-src]').forEach(function(e){e.src=e.getAttribute('data-src');});var fs=document.querySelector('script#fusion-metadata');if(fs&&fs.text.indexOf('Fusion.globalContent=')>=0){var json=JSON.parse(fs.text.split('Fusion.globalContent=')[1].split(';Fusion.')[0]);function findKey(o,k){if(!o||typeof o!=='object')return null;if(o[k]!=null)return o[k];for(var p in o){var r=findKey(o[p],k);if(r!=null)return r;}return null;}setTimeout(function(){try{var tts=document.querySelector('div > div#audio-panel > p[class^="ArticlePlayer__LoginCopy"]');if(tts){var a=findKey(json,'tts_audio');var src=a&&(a.url_en_M||a.url_en_F);if(src){var au=document.createElement('audio');au.src=src;au.controls=true;tts.parentNode.parentNode.replaceChild(au,tts.parentNode);}}var vid=document.querySelector('div > div.c-video:empty');if(vid){var streams=findKey(json,'streams');if(streams&&streams.length){var st=streams[streams.length-1];if(st.url){var v=document.createElement('video');v.src=st.url;v.controls=true;v.style.width='90%';vid.parentNode.replaceChild(v,vid);}}}}catch(e){}},2000);}var s=document.createElement('style');s.textContent='div.c-ad--base{display:none!important}';(document.head||document.documentElement).appendChild(s);}catch(e){}})();"##

        // Bloomberg — rebuild the article body from the in-page __NEXT_DATA__ JSON
        // (no fetch), strip the mask-image gradient, hide ads.
        m["bloomberg.com"] = ##"(function(){try{document.querySelectorAll('html[class],body[class]').forEach(function(e){e.removeAttribute('class');});if(!/s\/\d{4}-/.test(location.href))return;var sc=document.querySelector('script#__NEXT_DATA__');if(!sc)return;var json=JSON.parse(sc.text);var story=json.props.pageProps.story;var pars=story&&story.body&&story.body.content;var teasers=document.querySelectorAll('div > p[class^="ArticleBodyText_"]');if(!pars||!teasers.length||teasers.length>=5)return;var cls=teasers[0].getAttribute('class');var article=teasers[0].parentNode;article.style.setProperty('-webkit-mask-image','none','important');article.style.setProperty('mask-image','none','important');function text(items){var out='';(items||[]).forEach(function(it){if(it.type==='text'&&it.value)out+=it.value;else if(it.type==='link'&&it.data&&it.content)out+='<a href="'+(it.data.href||'')+'">'+text(it.content)+'</a>';else if(it.type==='entity'&&it.content&&it.content[0])out+=it.content[0].value;else if(it.content)out+=text(it.content);});return out;}pars.forEach(function(par){var elem=document.createElement('p');elem.setAttribute('class',cls);if(par.type==='heading')elem.style.fontWeight='bold';if((par.type==='heading'||par.type==='paragraph'||par.type==='div')&&par.content)elem.innerHTML=text(par.content);else if(par.type==='media'&&par.data){if(par.subType==='photo'&&par.data.photo&&par.data.photo.src){var im=document.createElement('img');im.src=par.data.photo.src;im.style.width='100%';elem.appendChild(im);}else if(par.subType==='video'&&par.data.video&&par.data.video.src){var v=document.createElement('video');v.src=par.data.video.src;v.controls=true;v.style.width='100%';elem.appendChild(v);}else if(par.subType==='chart'&&par.data.chart){var im2=document.createElement('img');im2.src=par.data.chart.fallback;im2.style.width='100%';elem.appendChild(im2);}}else if(par.content)elem.innerHTML=text(par.content);if(elem.hasChildNodes())article.appendChild(elem);});teasers.forEach(function(e){e.remove();});var s=document.createElement('style');s.textContent='div[id^="leaderboard"],div[class^="leaderboard"],div.canopy-container,div[data-ad-status],div[data-ad-type],div[class*="FullWidthAd_"],div.adWrapper,div.dvz-v0-ad{display:none!important}';(document.head||document.documentElement).appendChild(s);}catch(e){}})();"##

        // Australian Financial Review — same-origin fetch of the article, rebuild body
        // from __REDUX_STATE__ resolving image/link/youtube placeholders.
        m["afr.com"] = ##"(function(){try{var sel='#endOfArticle:not(:empty)';var article=document.querySelector(sel);if(!article){sel='#body-content';article=document.querySelector(sel);}if(!article)return;setTimeout(function(){try{var pars=article.querySelectorAll('p:not([class]),p[class*="-defaultWrapper"],figure:not(:empty)');if(!(pars.length&&pars.length<5))return;var url=location.href.split(/[#?]/)[0];fetch(url).then(function(r){return r.ok?r.text():Promise.reject();}).then(function(html){if(html.indexOf('__REDUX_STATE__=')<0)return;var json=JSON.parse(html.split('__REDUX_STATE__=')[1].split('};')[0].replace(/:undefined([,}])/g,':0$1').replace(/new\sMap\(\[[^{]*\]\)/g,0)+'}');var asset=json.page.content.asset;var body=asset.body;if(!body)return;var ph=asset.bodyPlaceholders;if(ph){body=body.replace(/<x-placeholder id="(\w+)"><\/x-placeholder>/g,function(mm,id){var it=ph[id];if(!it||!it.data)return '';var d=it.data;if((it.type==='linkArticle'||it.type==='linkExternal')&&d.text)return d.url?'<a href="'+d.url+'">'+d.text+'</a>':d.text;if(it.type==='image'&&d.fileName)return '<figure><img src="https://static.ffx.io/images/w_960/'+d.fileName+'" style="width:100%"><figcaption>'+(d.caption||'')+'</figcaption></figure>';if(it.type==='youtube'&&d.url&&d.url.indexOf('watch?v=')>=0)return '<iframe src="'+d.url.replace('watch?v=','embed/')+'" style="width:100%;height:400px"></iframe>';return '';});}var doc=new DOMParser().parseFromString('<div>'+body+'</div>','text/html');var content=doc.querySelector('div');pars.forEach(function(e){e.remove();});article.parentNode.replaceChild(content,article);content.id='endOfArticle';}).catch(function(){});}catch(e){}},1000);}catch(e){}})();"##

        return m
    }()
}
