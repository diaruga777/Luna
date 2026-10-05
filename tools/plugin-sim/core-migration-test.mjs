import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
import {createBridge} from './bridge.mjs';
const source = (name) => readFileSync(new URL('../../LunaLibraries/Sources/LunaBundledPlugins/Plugins/'+name+'.js',import.meta.url),'utf8');
function load(name,payload) {
  const luna = createBridge({capabilities:['html','fetch']});
  let fetches=0;
  luna.fetch=async () => {fetches++;return {ok:true,text:typeof payload==='string'?payload:JSON.stringify(payload)};};
  vm.runInNewContext(source(name),{luna});
  return {hooks:luna.__registeredHooks,count:()=>fetches};
}
for (const [fixture,id,expected] of [['x-video','2106513235541377525',true],['x-text','2106475141051945246',false]]) {
  const payload=JSON.parse(readFileSync(new URL('./fixtures/core-migration/'+fixture+'.json',import.meta.url),'utf8'));
  const {hooks}=load('x',payload);const url='https://x.com/author/status/'+id+'?s=20';
  const claim=hooks.classify({url});const result=await hooks.ingest({url,claim});
  assert.equal(!!result?.assets?.some(a=>a.type==='video'),expected);
}
const unrelated=load('x',{thread:[{id:'999',media:{all:[{type:'video',url:'https://cdn.example/v.mp4'}]}}]}).hooks;
assert.equal(await unrelated.ingest({url:'https://x.com/a/status/123',claim:{itemId:'123'}}),null);
assert.equal(unrelated.classify({url:'https://x.com/settings/a/status/123'}),false);
assert.equal(unrelated.classify({url:'https://x.com/home'}),false);
const body='<html><head><title>Test article</title></head><body><nav>Navigation</nav><article><h1>Test article</h1><p>'+('A real article paragraph with substantial useful content. '.repeat(30))+'</p><aside>Related stories</aside></article></body></html>';
const web=load('web',body).hooks;
const article=await web.ingest({url:'https://unknown.example/new-shape'});
assert.equal(article.kind,'article');assert.equal(article.title,'Test article');assert(!article.html.includes('Related stories'));
const product=load('web','<html><head><script type="application/ld+json">'+JSON.stringify({'@type':'Product',name:'A product',offers:{price:'42.95',priceCurrency:'AUD'},sku:'ABC'})+'</script></head><body></body></html>').hooks;
const item=await product.ingest({url:'https://unknown.example/p'});
assert.equal(item.kind,'product');assert.equal(item.price.amount,'42.95');assert.equal(item.price.currency,'AUD');
assert.equal(web.classify({url:'https://x.com/a/status/123',context:'safari',page:{html:body}}),false);
assert.equal(web.classify({url:'https://unknown.example/p',intent:'transcribe'}),false);
const wrapper=load('url-rewrites','').hooks;
const url='https://l.facebook.com/l.php?u='+encodeURIComponent('https://unknown.example/p?keep=1');
assert.equal((await wrapper.ingest({url})).rewriteURL,'https://unknown.example/p?keep=1');
console.log('Core plugin migration fixtures passed (video/text ownership, article, product, wrappers, intent).');

const redditLuna = createBridge({capabilities:['fetch','html']});
const listing = [{data:{children:[{data:{secure_media:{reddit_video:{fallback_url:'https://v.redd.it/id/DASH_720.mp4',has_audio:true,dash_url:'https://v.redd.it/id/DASHPlaylist.mpd'}}}}]}}];
redditLuna.fetch = async request => ({ok:true,text:request.url.includes('comments/') ? JSON.stringify(listing) : '<MPD><AdaptationSet mimeType="audio/mp4"><Representation><BaseURL>tracks/sound.m4a?x=1&amp;y=2</BaseURL></Representation></AdaptationSet></MPD>'});
vm.runInNewContext(source('reddit'),{luna:redditLuna});
const redditResult = await redditLuna.__registeredHooks.ingest({url:'https://reddit.com/comments/abc',claim:{itemId:'abc'}});
assert.equal(redditResult.assets[0].audioURL,'https://v.redd.it/id/tracks/sound.m4a?x=1&y=2');
assert.equal(redditResult.assets[0].headers.Referer,'https://www.reddit.com/');
assert.equal(redditResult.assets[0].dashManifestURL,undefined);
console.log('Plugin-owned Reddit DASH audio fixture passed.');

// Publisher interstitial parity: whole segments, every legacy key and same-site aliases.
for (const path of ['subscribe','subscriptions','paywall','log-in','register','checkout','remote/check_cookie.html']) {
  for (const key of ['dest','RETURNURL','return_url','redirecturl','next','targeturl']) {
    const target='https://news.example/story?edition=au';
    const wrapped='https://www.news.example/'+path+'?'+key+'='+encodeURIComponent(target);
    assert.equal((await wrapper.ingest({url:wrapped})).rewriteURL,target,wrapped);
  }
}
for (const url of ['https://news.example/subscriber-report?dest=https://news.example/story',
  'https://news.example/login?dest=https://evil.example/story',
  'https://news.example/login?dest=https://news.example/paywall',
  'https://facebook.com/l.php?u=https://facebook.com/home']) assert.equal(wrapper.classify({url}),false,url);
const classic=Buffer.concat([Buffer.from([8,19,34]),Buffer.from('https://publisher.test/story'),Buffer.from([0xd2,1,0])]).toString('base64url');
assert.equal((await wrapper.ingest({url:'https://news.google.com/articles/'+classic})).rewriteURL,'https://publisher.test/story');
console.log('URL wrapper parity regressions passed.');
