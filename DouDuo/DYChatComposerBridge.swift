import Foundation
import WebKit

/// The native input edits the official editor's model. It never replaces its
/// innerHTML, reconstructs a message payload, or bypasses the page's controls.
@MainActor
enum DYChatComposerBridge {
    struct Snapshot: Decodable {
        let id: String
        let text: String
        let canSend: Bool
    }
    enum Action: String { case attachment, emoji, send }
    enum EditFailure: String, Error {
        case conversationChanged, editorUnavailable, draftChanged, mappingUnavailable, writeRejected, writeNotConfirmed, bridgeUnavailable
        case sendUnavailable, sendUnconfirmed
    }

    static func read(_ web: WKWebView, id: String, height: CGFloat, bottom: CGFloat) async throws -> Snapshot {
        try await evaluate(web, id: id, script: "return snapshot();", values: ["height": height, "bottom": bottom])
    }

    static func edit(_ web: WKWebView, id: String, previous: String, text: String) async throws -> Snapshot {
        try await evaluate(web, id: id, script: editJS, values: ["previous": previous, "text": text, "isDraftWrite": true])
    }

    static func act(_ web: WKWebView, id: String, action: Action, expected: String, selection: NSRange) async throws -> Snapshot {
        try await evaluate(web, id: id, script: actionJS, values: [
            "action": action.rawValue, "expected": expected, "start": selection.location, "length": selection.length
        ])
    }

    private static func evaluate(_ web: WKWebView, id: String, script: String, values: [String: Any]) async throws -> Snapshot {
        let raw = try await web.callAsyncJavaScript(DYChatWebBridge.helpersJS + helpersJS + script,
            arguments: values.merging(["id": id]) { _, new in new }, contentWorld: .page)
        if let code = raw as? String, let failure = EditFailure(rawValue: code) { throw failure }
        guard let raw = raw as? String, let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(Snapshot.self, from: data), result.id == id else {
            throw DYChatWebBridge.BridgeError.unavailable
        }
        return result
    }

    static let helpersJS = #"""
    const failure=code=>typeof isDraftWrite==='undefined'?null:code;
    if (window.__ddNativeChatID !== id) return failure('conversationChanged');
    const row = document.querySelector('[class*="messageMsgInputinputRow"]');
    const element = row?.querySelector('[contenteditable]');
    let fiber = element?.[Object.keys(element).find(k=>k.startsWith('__reactFiber'))], editor;
    for (let i=0;fiber && i<8;i++,fiber=fiber.return) {
      if (fiber.memoizedProps?.editor) {editor=fiber.memoizedProps.editor;break;}
    }
    if (!editor || typeof editor.getContentState !== 'function' || typeof editor.getText !== 'function') return failure('editorUnavailable');
    const state=editor.getContentState(), zone=state.getZoneState('0');
    if (!zone || typeof state.replaceText !== 'function' || typeof zone.offsetToPoint !== 'function') return failure('editorUnavailable');
    const rawText=()=>editor.getText().replace(/\n$/, '');
    const actions=()=>row.querySelector('[class*="messageMsgInputinputAction"]');
    const sendButton=()=>actions()?.querySelector('.e2e-send-msg-btn');
    const snapshot=()=>{
      if(window.__ddNativeChatID!==id || !element.isConnected) return null;
      const latestZone=editor.getContentState().getZoneState('0');
      if(!latestZone) return null;
      const map=textMap(latestZone),point=modelPoint(latestZone,map,0);
      if(map.display.replace(/\n$/,'')!==rawText() || !Number.isInteger(point.line) || !Number.isInteger(point.offset)
        || typeof editor.modulesContainer.get('Range')!=='function') return null;
      document.documentElement.dataset.ddNativeComposer='true';
      if(typeof height !== 'undefined') document.documentElement.style.setProperty('--dd-native-composer-height',height+'px');
      if(typeof bottom !== 'undefined') document.documentElement.style.setProperty('--dd-native-composer-bottom',bottom+'px');
      element.setAttribute('inputmode','none');
      row.setAttribute('aria-hidden','true');
      if(!element.__ddNativeFocusGuard) {
        element.addEventListener('focus',()=>{if(document.documentElement.dataset.ddNativeComposer)element.blur();});
        element.__ddNativeFocusGuard=true;
      }
      const send=sendButton();
      return JSON.stringify({id,text:rawText(),canSend:!!send && !send.disabled && send.getAttribute('aria-disabled')!=='true'
        && Number(getComputedStyle(send).opacity)>0.5});
    };
    // Map the displayed text to model offsets. An emoji/mention may occupy one
    // model token but several displayed characters; retain untouched attributes.
    const textMap=(zone)=>{
      let display='',offset=0;const segments=[];
      for(let line=0;line<zone.length();line++) {
        const item=zone.getLine(line),ops=item.getOps();
        for(let i=0;i<ops.length;i++) {
          const op=ops[i];
          const size=typeof op.insert==='string'?op.insert.length:1;
          if(i===0 && item.hasLineMarker()) {offset+=size;continue;}
          const token={text:op.insert,attributes:{...op.attributes}};
          editor.pluginManager?.call('editorCollectText',token);
          const shown=typeof token.text==='string'?token.text:'';
          segments.push({start:display.length,end:display.length+shown.length,offset,size,atomic:shown!==op.insert});
          display+=shown;offset+=size;
        }
      }
      const point=(index,end=false)=>{
        for(const part of segments) if(index>=part.start && (index<part.end || end && index===part.end)) {
          return part.offset+(part.atomic?(end?part.size:0):Math.min(part.size,index-part.start));
        }
        return Math.max(0,offset-1);
      };
      return {display,segments,point};
    };
    const modelPoint=(zone,map,index,end=false)=>({...zone.offsetToPoint(map.point(index,end)),zoneId:'0'});
    const select=(start,length)=>{
      const map=textMap(zone),Range=editor.modulesContainer.get('Range');
      const range=new Range({editor,start:modelPoint(zone,map,start),end:modelPoint(zone,map,start+length,length>0)});
      editor.selection.setSelection(range,false);
    };
    """#

    static let editJS = #"""
    const current=rawText();
    if(current!==text && current!==previous) return 'draftChanged';
    if(current!==text) {
      let prefix=0,suffix=0;
      while(prefix<current.length && prefix<text.length && current[prefix]===text[prefix]) prefix++;
      while(suffix<current.length-prefix && suffix<text.length-prefix
        && current[current.length-1-suffix]===text[text.length-1-suffix]) suffix++;
      const map=textMap(zone);
      if(map.display.replace(/\n$/,'')!==current) return 'mappingUnavailable';
      let end=current.length-suffix;
      for(const part of map.segments) {
        if(part.atomic && prefix>part.start && prefix<part.end) prefix=part.start;
        if(part.atomic && end>part.start && end<part.end) {suffix=current.length-part.end;end=part.end;}
      }
      const Range=editor.modulesContainer.get('Range');
      const range=new Range({editor,start:modelPoint(zone,map,prefix),end:modelPoint(zone,map,end,end>prefix)});
      try {
        editor.setPreventUpdateDomSelection?.(true);
        try {state.replaceText(range,text.slice(prefix,text.length-suffix));}
        finally {editor.setPreventUpdateDomSelection?.(false);}
      } catch {return 'writeRejected';}
    }
    // The webpage may commit a new editor state on its next update.
    for(let attempt=0;attempt<=8;attempt++) {
      if(window.__ddNativeChatID!==id || !element.isConnected) return 'conversationChanged';
      if(rawText()===text) {
        const updated=snapshot();
        if(updated) return updated;
      }
      if(attempt<8) await sleep(25);
    }
    return 'writeNotConfirmed';
    """#

    static let actionJS = #"""
    if(rawText()!==expected) return action==='send'?'sendUnavailable':null;
    let target;
    if(action==='attachment') target=actions()?.querySelector('.semi-upload-add');
    if(action==='emoji') target=actions()?.querySelector('[class*="messageMsgInputiconAction"]');
    if(action==='send') {
      for(let attempt=0;attempt<=8;attempt++) {
        if(window.__ddNativeChatID!==id || !element.isConnected || rawText()!==expected) return 'sendUnavailable';
        target=sendButton();
        if(target && !target.disabled && target.getAttribute('aria-disabled')!=='true' && Number(getComputedStyle(target).opacity)>0.5) {
          invoke(target);
          for(let confirmation=0;confirmation<=20;confirmation++) {
            if(window.__ddNativeChatID!==id || !element.isConnected) return 'sendUnconfirmed';
            if(rawText()==='') {
              const updated=snapshot();
              if(updated) return updated;
            }
            if(confirmation<20) await sleep(25);
          }
          return 'sendUnconfirmed';
        }
        if(attempt<8) await sleep(25);
      }
      return 'sendUnavailable';
    }
    if(!target) return null;
    if(action==='emoji') {
      const caret=Math.max(0,Math.min(start,expected.length));
      select(caret,Math.max(0,Math.min(length,expected.length-caret)));
    }
    invoke(target);
    return snapshot();
    """#
}
