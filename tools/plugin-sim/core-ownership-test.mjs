import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {createBridge} from './bridge.mjs';
const root=new URL('../../',import.meta.url);
const read=p=>readFileSync(new URL(p,root),'utf8');
function plugin(name,fetcher){const luna=createBridge({capabilities:['html','fetch','browser']});luna.fetch=fetcher;const ctx=vm.createContext({luna});vm.runInContext(read('LunaLibraries/Sources/LunaBundledPlugins/Plugins/'+name+'.js'),ctx);return {ctx,luna,hooks:luna.__registeredHooks};}
const fixture=n=>read('LunaTests/Fixtures/Products/'+n+'.html');
const cases=[['amazon-dp','https://amazon.com/dp/B12345678'],['amazon-listprice','https://amazon.com/dp/B12345678'],['target-nextdata','https://target.com/p/test/-/A-123'],['walmart-nextdata','https://walmart.com/ip/test/123'],['google-shopping-mova','https://google.com/search?tbm=shop&q=mova'],['google-shopping-ibp-oshop','https://google.com/search?ibp=oshop&prds=productid:123']];
for(const [name,url] of cases){const html=fixture(name),p=plugin('web',async()=>({ok:true,text:html,url}));const result=await p.hooks.ingest({url,reason:'save'});assert.equal(result?.kind,'product',name);assert(Number(result.price.amount)>0,name);if(name.startsWith('google'))assert(result.sellers.length>0);console.log(name,result.price);}
const storefront=plugin('web',async()=>({ok:false}));
assert.equal(vm.runInContext('LunaShop.product(luna.html.parse('+JSON.stringify(fixture('amazon-dp'))+',"https://amazon.com.au/dp/X"),"https://amazon.com.au/dp/X").price.currency',storefront.ctx),'AUD');
assert.equal(vm.runInContext('LunaShop.matches({name:"Sony headphones WH-1000XM5",identifiers:{mpn:"WH1000XM5"}},{name:"Sony headphones WH-1000XM4",identifiers:{mpn:"WH1000XM4"}})',storefront.ctx),false);
const sourceProduct={kind:'product',name:'Sony WH-1000XM5 wireless headphones',price:{amount:'299',currency:'USD'},identifiers:{mpn:'WH1000XM5'}};
let fetches=[];const compare=plugin('web',async req=>{fetches.push(req.url);const u=new URL(req.url);return {ok:true,url:req.url,text:u.pathname.includes('/products/test')?'<script type="application/ld+json">'+JSON.stringify({'@type':'Product',name:sourceProduct.name,mpn:'WH1000XM5',offers:{price:'199',priceCurrency:'USD'}})+'</script>':'<a href="/products/test">Sony WH-1000XM5 wireless headphones</a>'};});
compare.ctx.input=sourceProduct;const sellers=await vm.runInContext('LunaShop.compare(input,"https://original.test/item")',compare.ctx);assert(sellers.sellers.length>0);assert(fetches.length<=24);assert(sellers.sellers.every(s=>s.price.currency==='USD'));assert(sellers.sellers.every(s=>s.price.amount==='199'));
const full='<article><h1>Recovered article</h1><p>'+('Verified article text. '.repeat(100))+'</p></article>';
const gated='<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script><article><p>Subscribe to read</p></article>';
let strategies=[];const access=plugin('publisher-access',async req=>{strategies.push(req);return {ok:true,text:req.url.includes('?amp')?full:gated,url:req.url};});
const result=await access.hooks.ingest({url:'https://theaustralian.com.au/news/story',reason:'save'});assert.equal(result.kind,'article');assert(strategies.some(r=>r.url.endsWith('?amp')));assert(strategies.some(r=>r.cookies==='none'));
const untouched=plugin('publisher-access',async()=>{throw Error('network should not be reached');});assert.equal(untouched.hooks.classify({url:'https://x.com/a/status/123'}),false);
const browser=plugin('publisher-access',async req=>({ok:true,text:gated,url:req.url}));let request;browser.luna.browser={open:async r=>{request=r;return {html:full,url:r.url};}};
const restored=await browser.hooks.ingest({url:'https://example.test/premium',saveId:'test',reason:'save'});assert.equal(restored.kind,'article');assert(request.scripts.length>0);assert(Array.isArray(request.blockURLs));
console.log('Core ownership fixtures passed: retail prices, shopping sellers, matching/fanout, publisher strategy and browser declarations.');
// Safari has no save ID yet: the browser-deferred result must reach its save handoff.
const safari=plugin('publisher-access',async req=>({ok:true,text:gated,url:req.url}));
safari.luna.browser={open:async()=>{throw Object.assign(Error('deferred'),{code:'browser-deferred'});}};
await assert.rejects(safari.hooks.ingest({url:'https://example.test/premium',context:'safari',reason:'save'}),{code:'browser-deferred'});

// Daily Beast's Astro continuation must survive generic gate detection.
const beastURL='https://www.thedailybeast.com/animated-pete-hegseth-snaps-at-press-during-wild-pentagon-briefing';
const beastHTML=read('LunaTests/Fixtures/Plugins/dailybeast-astro.html');
for(const suppliedPage of [true,false]) {
    const requests=[];
    const beast=plugin('publisher-access',async req=>{requests.push(req.url);return {ok:true,text:beastHTML,url:req.url};});
    beast.luna.browser={open:async()=>{throw Error('complete Daily Beast response must not need a browser');}};
    const answer=await beast.hooks.ingest({url:beastURL,context:'share',reason:'save',saveId:'beast',
        page:suppliedPage?{url:beastURL,html:beastHTML}:undefined});
    assert.equal(answer?.kind,'article');
    for(let n=1;n<=6;n++)assert(answer.html.includes('Paragraph '+n+'.'));
    assert(answer.html.indexOf('Paragraph 1.')<answer.html.indexOf('fixture.jpg'));
    assert(answer.html.indexOf('fixture.jpg')<answer.html.indexOf('Paragraph 2.'));
    assert(answer.html.includes('inline source'));
    assert(!answer.html.includes('must not appear'));
    assert(!answer.html.includes('Subscribe to read'));
    assert.deepEqual(requests,suppliedPage?[]:[beastURL]);
}
const shape=plugin('publisher-access',async()=>({ok:false}));
// New Yorker's JSON-LD omits the intro while the DOM labels later prose paywall.
const newYorkerURL='https://www.newyorker.com/magazine/2026/10/05/cookie-monster-tries-to-meet-his-ai-mandate';
const newYorkerHTML=read('LunaTests/Fixtures/Plugins/newyorker-paywall-paragraphs.html');
for(const pluginName of ['web','publisher-access']) for(const context of ['app','share','safari']) for(const suppliedPage of [true,false]) {
    const requests=[];
    const publisher=plugin(pluginName,async req=>{requests.push(req.url);return {ok:true,text:newYorkerHTML,url:req.url};});
    publisher.luna.browser={open:async()=>{throw Error('complete New Yorker response must not need a browser');}};
    const answer=await publisher.hooks.ingest({url:newYorkerURL,context,reason:'save',saveId:'newyorker',
        page:suppliedPage?{url:newYorkerURL,html:newYorkerHTML}:undefined});
    assert.equal(answer?.kind,'article');
    const doc=publisher.luna.html.parse(answer.html,newYorkerURL);
    const paragraphs=doc.querySelectorAll('p');
    assert.equal(paragraphs.length,22);
    assert(paragraphs[0].textContent.startsWith('Me resident cookie expert'));
    assert(paragraphs[1].textContent.startsWith('Matt here to'));
    for(let n=2;n<=22;n++)assert(paragraphs[n-1].textContent.includes('Paragraph '+String(n).padStart(2,'0')+'.'));
    assert.equal(answer.title,'New Yorker regression');
    assert.equal(answer.author,'Fixture Reporter');
    assert(answer.html.includes('inline source'));
    assert(answer.html.includes('fixture.jpg'));
    assert(!answer.html.includes('must not appear'));
    assert.deepEqual(requests,suppliedPage?[]:[newYorkerURL]);
}
shape.ctx.newYorkerHTML=newYorkerHTML;
const otherHost=vm.runInContext('LunaAccess.article(newYorkerHTML,"https://newyorker.com.unrelated.example/story")',shape.ctx);
assert(!otherHost.html.includes('Me resident cookie expert'),'publisher normalization must not affect other hosts');
shape.ctx.newYorkerTeaser='<html><head><script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script></head><body><article><div data-testid="BodyWrapper"><div class="body__inner-container"><p>Only the opening is available.</p><p class="paywall">Subscribe to read the rest of this article.</p></div></div></article></body></html>';
assert.equal(vm.runInContext('LunaAccess.article(newYorkerTeaser,"https://www.newyorker.com/story")',shape.ctx),null,'a real subscription notice must not become an article');
shape.ctx.beastHTML=beastHTML;
assert.equal(vm.runInContext('LunaAccess.article(beastHTML,"https://unrelated.example/story")',shape.ctx),null,'publisher normalization must be host scoped');
shape.ctx.teaser='<html><head><script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script></head><body><article id="article-content"><p data-block-type="text">'+('A metered teaser. '.repeat(70))+'</p><div class="tdb-paywall">Subscribe to read</div></article></body></html>';
assert.equal(vm.runInContext('LunaAccess.article(teaser,"https://www.thedailybeast.com/story")',shape.ctx),null,'a teaser alone must remain locked');
const crawlerRequests=[];
const crawler=plugin('publisher-access',async req=>{
    crawlerRequests.push(req);
    return {ok:true,text:req.userAgent?.includes('Google-InspectionTool')?beastHTML:shape.ctx.teaser,url:req.url};
});
crawler.luna.browser={open:async()=>{throw Error('readable crawler response must not open a browser');}};
const crawlerAnswer=await crawler.hooks.ingest({url:beastURL,context:'share',reason:'save',saveId:'beast',page:{url:beastURL,html:shape.ctx.teaser}});
assert.equal(crawlerAnswer?.kind,'article');
assert(crawlerAnswer.html.includes('Paragraph 6.'));
assert(crawlerRequests.every(req=>req.url===beastURL),'crawler success must not fall through to archive lookups');

// A readable archive must not wait for the other snapshot lookup to finish.
const archived=plugin('publisher-access',async req=>{
    if(req.url.includes('/cdx/')) {
        if(!req.url.includes('sort=reverse'))return new Promise(()=>{});
        return {ok:true,text:JSON.stringify([['timestamp'],['20260307154638']]),url:req.url};
    }
    return {ok:true,text:req.url.includes('/web/')?full:gated,url:req.url};
});
archived.luna.browser={open:async()=>{throw Error('readable archive must not open a browser');}};
let archiveTimer;
const archiveAnswer=await Promise.race([
    archived.hooks.ingest({url:beastURL,saveId:'test',reason:'save'}),
    new Promise(resolve=>{archiveTimer=setTimeout(()=>resolve(null),500);})
]);
clearTimeout(archiveTimer);
assert.equal(archiveAnswer?.kind,'article','a stalled oldest lookup must not hold a readable latest snapshot');

// WSJ and Mint use different headlines/slugs for the Hassabis profile. Only
// the index's structured summary shares his name with the original URL.
const wsjURL='https://www.wsj.com/tech/ai/demis-hassabis-ai-deepmind-google-isomorphic-2b4e3153';
const mintURL='https://www.livemint.com/global/why-ai-s-deepest-mind-believes-the-world-is-about-to-change-radically-11792584394493.html';
const mintIndex='<a href="/global/unrelated-story-123.html">Other reporting</a><a href="'+mintURL+'">A different headline</a>'+
    '<script type="application/ld+json">'+JSON.stringify({'@type':'ItemList',itemListElement:[null,
        {url:mintURL,name:'A different headline',description:'A profile of Demis Hassabis.'}]})+'</script>';
const mintCopy=canonical=>'<html><head><title>Syndicated profile</title><link rel="canonical" href="'+canonical+'">'+
    '<script type="application/ld+json">{"@type":"NewsArticle","articleBody":"Opening only."}</script></head><body><div id="mainArea">'+
    '<div class="storyParagraph"><p>Opening profile paragraph.</p></div><div class="paywall-slot"><div class="storyParagraph">'+
    '<p>'+('Complete profile reporting. '.repeat(150))+'</p><p>Final profile paragraph.</p></div></div></div></body></html>';
for(const context of ['app','share','safari']) {
    const requests=[];
    const syndicated=plugin('publisher-access',async req=>{
        requests.push(req.url);
        return {ok:true,url:req.url,text:req.url==='https://www.livemint.com/wsj'?mintIndex:req.url===mintURL?mintCopy(wsjURL):gated};
    });
    syndicated.luna.browser={open:async()=>{throw Error('verified syndicated copy must not need a browser');}};
    const answer=await syndicated.hooks.ingest({url:wsjURL,context,reason:'save',saveId:'wsj',page:{url:wsjURL,html:gated}});
    assert.equal(answer?.kind,'article');
    assert.equal(answer.baseURL,mintURL);
    assert(answer.html.includes('Opening profile paragraph.'));
    assert(answer.html.includes('Final profile paragraph.'));
    assert.equal(requests.filter(u=>new URL(u).hostname==='www.livemint.com').length,2,'request only the index and relevant copy');
}
for(const canonical of ['https://www.wsj.com/tech/ai/another-story-12345678','https://wsj.com.unrelated.example'+new URL(wsjURL).pathname]) {
    const syndicated=plugin('publisher-access',async req=>({ok:true,url:req.url,
        text:req.url==='https://www.livemint.com/wsj'?mintIndex:req.url===mintURL?mintCopy(canonical):gated}));
    assert.equal(await syndicated.hooks.ingest({url:wsjURL,context:'app',reason:'save'}),null,'index text cannot override canonical identity');
}
const candidateRequests=[];
const bounded=plugin('publisher-access',async req=>{
    if(req.url==='https://www.livemint.com/wsj')return {ok:true,text:Array.from({length:10},(_,i)=>
        '<a href="/global/demis-hassabis-profile-'+i+'.html">Demis Hassabis</a>').join('')};
    if(new URL(req.url).hostname==='www.livemint.com')candidateRequests.push(req.url);
    return {ok:true,text:gated,url:req.url};
});
assert.equal(await bounded.hooks.ingest({url:wsjURL,context:'app',reason:'save'}),null);
assert.equal(candidateRequests.length,3,'syndication discovery must stay bounded');
console.log('WSJ syndication fixtures passed: renamed headlines, canonical identity, complete continuation and bounded discovery.');
