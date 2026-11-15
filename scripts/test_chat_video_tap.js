// Executes the production resolver against redacted real IM payloads.
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const source = fs.readFileSync('DouDuo/DouyinWebView.swift','utf8');
const hook = source.match(/private let ddVideoTapHookJS = #"""\n([\s\S]*?)\n"""#/)[1];
const resolver = hook.slice(hook.indexOf('  const findID ='),hook.indexOf('  document.addEventListener'));
const ctx = vm.createContext({}); vm.runInContext(resolver + '\nthis.resolve = findID;',ctx);
function element(props = {}, parent = null, attrs = []) {
  return Object.assign({parentElement:parent,attributes:attrs,querySelector(){return null;},querySelectorAll(){return [];}},props);
}
let failures = 0, passed = 0;
function test(name, fn){try{fn();passed++;console.log('PASS',name);}catch(e){failures++;console.error('FAIL',name,e.message);}}
const samples = JSON.parse(fs.readFileSync('scripts/fixtures/chat-shared-videos.json','utf8'));
for(const [i,s] of samples.entries()){
  test(`real IM sample ${i}: parsedContent on parent fiber`,()=>{
    const root=element({__reactFiber_test:{memoizedProps:{},return:{memoizedProps:{message:{parsedContent:s}}}}});
    assert.strictEqual(ctx.resolve(root),s.itemId);
  });
  test(`real IM sample ${i}: content JSON fallback`,()=>{
    const root=element({__reactProps_test:{message:{content:JSON.stringify(s)}}});
    assert.strictEqual(ctx.resolve(root),s.itemId);
  });
}
test('reject unrelated user ID attribute',()=>assert.strictEqual(ctx.resolve(element({},null,[{name:'data-user-id',value:'7559098237669180473'}])),null));
test('reject generic itemId outside shared-video payload',()=>assert.strictEqual(ctx.resolve(element({__reactProps_x:{itemId:'7704206030490512036'}})),null));
test('reject unsafe numeric ID',()=>assert.strictEqual(ctx.resolve(element({__reactProps_x:{message:{parsedContent:{aweType:800,itemId:Number(samples[0].itemId)}}}})),null));
test('malformed content fails closed',()=>assert.strictEqual(ctx.resolve(element({__reactProps_x:{message:{content:'{'}}})),null));
test('do not cross into another message row',()=>{
 const outer=element({__reactProps_x:{message:{parsedContent:samples[0]}}});
 const inner=element({__reactProps_x:{message:{parsedContent:{aweType:7,itemId:samples[1].itemId}}}},outer);
 assert.strictEqual(ctx.resolve(inner),null);
});
function clickThroughHook(payload, pathname='/chat') {
  let listener; const sent=[]; const ev={prevented:false,stopped:false,
    preventDefault(){this.prevented=true;},stopPropagation(){this.stopped=true;}};
  const pane=element({className:'componentsRightPanelwrapper'});
  const card=element({className:'MessageItemShareAwemecontainer',__reactFiber_test:{memoizedProps:{},return:{memoizedProps:{message:{parsedContent:payload}}}}},pane);
  const play=element({className:'MessageItemShareAwemeplayIcon'},card);
  play.closest=selector=>selector.includes('componentsRightPanel')?pane:play;
  ev.target=play;
  vm.runInNewContext(hook,{location:{pathname},document:{addEventListener(_,fn){listener=fn;}},console:{log(){}},window:{webkit:{messageHandlers:{ddMsg:{postMessage(v){sent.push(JSON.parse(v));}}}}}});
  listener(ev);return {ev,sent};
}
test('real play-icon click posts exact video ID and intercepts web playback',()=>{
 const r=clickThroughHook(samples[0]);assert.strictEqual(r.sent[0].id,samples[0].itemId);
 assert.strictEqual(r.sent[0].type,'video');assert(r.ev.prevented&&r.ev.stopped);
});
test('unknown message leaves official click alone',()=>{
 const r=clickThroughHook({aweType:7,itemId:samples[0].itemId});
 assert(!r.ev.prevented&&!r.ev.stopped);assert.strictEqual(r.sent[0].type,'video-miss');
});
test('non-chat routes are never intercepted',()=>{
 const r=clickThroughHook(samples[0],'/video/123');assert.strictEqual(r.sent.length,0);assert(!r.ev.prevented);
});
console.log({passed,failures});process.exitCode=failures?1:0;
