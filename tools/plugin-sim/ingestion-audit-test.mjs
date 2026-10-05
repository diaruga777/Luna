import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {createBridge} from './bridge.mjs';
const read=p=>readFileSync(new URL('../../'+p,import.meta.url),'utf8');
const luna=createBridge({capabilities:['html','fetch']});
let response;
luna.fetch=async()=>response;
vm.runInNewContext(read('LunaLibraries/Sources/LunaBundledPlugins/Plugins/web.js'),{luna});
let failures=[];
for(const c of JSON.parse(read('LunaTests/Fixtures/Plugins/web-parity.json'))){
 try {
  const result=await luna.__registeredHooks.ingest({url:c.url,page:{url:c.url,html:c.html}});
  if(c.isNull)assert.equal(result,null,c.name);
  else {
   assert.equal(result?.kind,'article',c.name);
   for(const value of c.contains)assert(result.html.includes(value),c.name+' missing '+value.slice(0,50));
   for(const value of c.excludes)assert(!result.html.includes(value),c.name+' retained '+value);
  }
 } catch(error){failures.push(error.message);}
}
if(failures.length){console.error(failures.join('\n'));process.exitCode=1;}
else console.log('Shared article migration parity fixtures passed.');
for(const [fixture,url,amount,currency] of [
 ['bunnings-nextdata','https://bunnings.com.au/widget_p123','99','AUD'],
 ['nested-currency-state','https://shop.example/products/skort','49.9','AUD']
]){
 response={ok:true,url,text:read('LunaTests/Fixtures/Products/'+fixture+'.html')};
 const model=await luna.__registeredHooks.ingest({url});
 assert.equal(model?.kind,'product',fixture);assert.equal(model.price.amount,amount);assert.equal(model.price.currency,currency);
}
response={ok:true,url:'https://shop.example/products/skort',text:read('LunaTests/Fixtures/Products/nested-currency-state.html')};
assert.equal((await luna.__registeredHooks.ingest({url:'http://shop.example/products/skort',reason:'refresh'}))?.price.amount,'49.9');
response={ok:true,url:'https://news.example/subscribe',text:'<article><p>'+('Buy our subscription plan. '.repeat(100))+'</p></article>'};
assert.equal(await luna.__registeredHooks.ingest({url:'https://news.example/story'}),null,'subscription redirects must allow publisher access, not rewrite into a cycle');
console.log('Embedded product and owner refresh regressions passed.');
