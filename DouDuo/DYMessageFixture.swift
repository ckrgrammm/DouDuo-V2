#if DEBUG
import Foundation

/// A disconnected HTML document with no account cookies, network, or send handler.
/// Only explicit UI-test launches use it; release builds contain no fixture.
enum DYMessageFixture {
    static var enabled: Bool { ProcessInfo.processInfo.environment["DOUDUO_MESSAGE_FIXTURE"] == "1" }
    static let scope = "message-layout-fixture"
    static var page: String {
        guard ProcessInfo.processInfo.environment["DOUDUO_FIXTURE_REJECT_DRAFT"] == "1" else { return html }
        return html.replacingOccurrences(of: "<script>", with: "<script>window.fixtureRejectDraft = true;")
    }

    static let html = #"""
    <!doctype html><html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:">
    <style>
    *{box-sizing:border-box}html,body{height:100%;margin:0;color:#fff;background:#000;font:16px -apple-system}
    .chatDark,.componentsEntrywrapper{height:100%;width:100%;display:flex}
    .semi-resizable-resizable{width:300px;overflow:auto}
    [data-e2e=conversation-item]{padding:12px;min-height:72px}
    .componentsRightPanelwrapper,.componentsRightPanelnotHeaderArea{display:flex;flex-direction:column;flex:1;min-height:0}
    .RightPanelHeaderconvHeader{height:60px;display:flex;align-items:center}
    .messageMessageListwrapper{flex:1;min-height:0;overflow:hidden}
    .messageMessageListlist{height:100%;overflow:auto;padding:16px}
    .bubble{max-width:78%;padding:12px 16px;border-radius:20px;background:#242428;margin:12px 0;line-height:1.5}
    .bubble.mine{margin-left:auto;background:#33474c}
    .messageMsgInputinputRow{display:flex;align-items:center;gap:8px}
    .messageEditorimChatEditorContainer{flex:1;min-width:0}
    [contenteditable]{outline:0;white-space:pre-wrap;overflow-wrap:anywhere}
    [contenteditable]:empty:before{content:attr(data-placeholder);color:#999}
    .messageMsgInputinputAction{display:flex;gap:10px}
    button{color:inherit;background:transparent;border:0;font:inherit;min-width:32px;min-height:36px}
    .conversationConversationInfowrapper{position:absolute;right:0;top:0;width:300px;background:#242428;display:none}
    .conversationConversationInfoopen{display:block}
    .ConversationInfoConversationInfoItemitemContainer{padding:16px;display:flex;justify-content:space-between}
    .ConversationItemMenuwrapper{position:fixed;top:100px;left:24px;background:#222;z-index:99}
    .ConversationItemMenumenuItem{padding:16px}
    </style></head><body>
    <div class="chatDark"><div class="componentsEntrywrapper">
    <div class="semi-resizable-resizable"><div class="ConversationListwrapper" id="rows"></div></div>
    <div class="componentsRightPanelwrapper" id="panel"></div>
    </div></div>
    <script>
    const people=[
      {id:'fixture-a',name:'青禾',text:'晚点见，路上注意安全。',streak:'128',pinned:false},
      {id:'fixture-b',name:'一起去看海',text:'这张照片拍得很好看。',streak:'32',pinned:true},
      {id:'fixture-c',name:'名字很长的测试联系人用来核对窄栏',text:'下次一起出去走走。',streak:'365',pinned:false},
      {id:'fixture-d',name:'小满',text:'收到，谢谢。',streak:'',pinned:false}
    ];
    let selected=null,muted=false;
    const flame=s=>s?'<span class="commonStreakstreakContainer"><span>'+s+'</span></span>':'';
    const rowFor=id=>document.querySelector('[data-id="'+id+'"]');
    function renderRows(){
      document.getElementById('rows').innerHTML='';
      people.forEach(p=>{
        const e=document.createElement('div');e.dataset.e2e='conversation-item';e.dataset.id=p.id;
        e.className='conversationConversationItemwrapper'+(p.pinned?' conversationConversationItemisStickOnTop':'');
        e.innerHTML='<div class="conversationConversationItemtitle">'+p.name+'</div>'+flame(p.streak)+'<span class="timeStr">10:30</span><div class="ConversationItemHinttextBox">'+p.text+'</div>';
        e.__reactFiber$fixture={memoizedProps:{conversation:{id:p.id,type:p.id==='fixture-b'?2:1,
          toParticipantUserId:p.id==='fixture-a'?'fixture-user-a':p.id,
          shortId:p.id==='fixture-b'?'fixture-group':p.id}}};
        e.addEventListener('mousedown',event=>{if(event.button===0)open(p)});
        e.addEventListener('contextmenu',event=>{event.preventDefault();menu(p)});
        document.getElementById('rows').append(e);
      });
    }
    function settings(){
      const e=document.getElementById('settings');
      e.innerHTML=['消息免打扰','置顶聊天','举报'].map((title,index)=>'<div class="ConversationInfoConversationInfoItemitemContainer"><div class="ConversationInfoConversationInfoItemleftArea">'+title+'</div>'+(index<2?'<input type="checkbox" role="switch" '+((index===0?muted:selected.pinned)?'checked':'')+'>':'<button>查看</button>')+'</div>').join('');
      const controls=e.querySelectorAll('input');
      controls[0].addEventListener('change',()=>{muted=controls[0].checked});
      controls[1].addEventListener('change',()=>{selected.pinned=controls[1].checked;renderRows()});
    }
    function open(p){
      selected=p;
      document.getElementById('panel').innerHTML='<div class="RightPanelHeaderconvHeader"><div id="ei-conversation-header-info"><div data-apm-action="个人页卡片"><span class="RightPanelHeadertitle">'+p.name+'</span></div>'+flame(p.streak)+'</div><button id="ei-conversation-header-title-bar">更多</button></div><div class="componentsRightPanelnotHeaderArea"><div class="messageMessageListwrapper"><div class="messageMessageListlist">'+Array.from({length:10},(_,i)=>'<div class="bubble '+(i%2?'mine':'')+'">'+(i%2?'好呀，周末见。':'今天的风景很好，想与你分享。')+'</div>').join('')+'</div></div><div class="componentsRightPanelinputArea"><div class="messageMsgInputcontainer"><div class="messageMsgInputinputColumn"><div class="messageMsgInputinputRow"><div class="messageEditorimChatEditorContainer"><div class="messageEditorinputArea" contenteditable="true" role="textbox" aria-label="本地测试草稿" data-placeholder="发送消息"></div></div><div class="messageMsgInputinputAction"><button aria-label="附件">＋</button><button aria-label="表情">☺</button><button aria-label="发送（本地测试禁用）" disabled>↑</button></div></div></div></div></div></div><div class="conversationConversationInfowrapper" id="settings"></div>';
      const more=document.getElementById('ei-conversation-header-title-bar');
      const editorElement=document.querySelector('[contenteditable]');
      editorElement.textContent=p.draft||'';
      const plain=()=>editorElement.textContent;
      const position=point=>plain().split('\n').slice(0,point.line).reduce((n,s)=>n+s.length+1,0)+point.offset;
      const zone={
        length:()=>plain().split('\n').length,
        getLine:i=>({getOps:()=>[{insert:plain().split('\n')[i]+'\n'}],hasLineMarker:()=>false}),
        offsetToPoint:offset=>{const lines=plain().split('\n');let line=0;while(line<lines.length-1&&offset>lines[line].length){offset-=lines[line].length+1;line++;}return {line,offset};}
      };
      const state={getZoneState:()=>zone,replaceText:(range,text)=>{
        if(window.fixtureRejectDraft && p.id==='fixture-a') throw Error('Offline draft write failure');
        editorElement.textContent=plain().slice(0,position(range.start))+text+plain().slice(position(range.end));
        p.draft=plain();
      }};
      const editor={getText:()=>plain()+'\n',getContentState:()=>state,pluginManager:{call(){}},
        modulesContainer:{get:()=>class{constructor(value){Object.assign(this,value)}}},selection:{setSelection(){}},setPreventUpdateDomSelection(){}};
      editorElement.__reactFiber$fixture={memoizedProps:{editor}};
      more.__reactProps$fixture={onClick:()=>{document.getElementById('settings').classList.toggle('conversationConversationInfoopen');settings()}};
      settings();
      const list=document.querySelector('.messageMessageListlist');list.scrollTop=list.scrollHeight;
    }
    function menu(p){
      document.querySelector('.ConversationItemMenuwrapper')?.remove();
      const e=document.createElement('div');e.className='ConversationItemMenuwrapper';
      [p.pinned?'取消置顶':'置顶','删除'].forEach((title,index)=>{
        const b=document.createElement('div');b.className='ConversationItemMenumenuItem';b.textContent=title;
        b.addEventListener('click',()=>{
          if(index===0)p.pinned=!p.pinned;
          else people.splice(people.indexOf(p),1);
          renderRows();e.remove();
        });e.append(b);
      });document.body.append(e);
    }
    document.addEventListener('keydown',e=>{if(e.key==='Escape')document.querySelector('.ConversationItemMenuwrapper')?.remove()});
    renderRows();
    </script></body></html>
    """#
}
#endif
