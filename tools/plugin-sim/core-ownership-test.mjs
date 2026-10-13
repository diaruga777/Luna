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

// A readable archive must not wait for the other snapshot lookup to finish.
const beastURL='https://www.thedailybeast.com/animated-pete-hegseth-snaps-at-press-during-wild-pentagon-briefing';
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
