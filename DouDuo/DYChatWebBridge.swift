import Foundation
import WebKit

/// All mutations go through the official page's existing controls. A missing
/// control or an unconfirmed result is an error, never an optimistic success.
@MainActor
enum DYChatWebBridge {
    enum Action: String { case pin, unpin, delete }
    enum BridgeError: Error { case unavailable }

    static func snapshot(_ web: WKWebView, headerInset: CGFloat = 72) async -> DYChatChromeSnapshot? {
        guard let text = try? await web.callAsyncJavaScript(
            "document.documentElement.style.setProperty('--dd-header-inset', inset+'px'); return " + snapshotJS,
            arguments: ["inset": headerInset], contentWorld: .page) as? String,
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DYChatChromeSnapshot.self, from: data)
    }

    static func options(_ web: WKWebView, id: String) async throws -> [DYChatOption] {
        let text = try await web.callAsyncJavaScript(helpersJS + optionsJS, arguments: ["id": id], contentWorld: .page)
        guard let text = text as? String, let data = text.data(using: .utf8) else { throw BridgeError.unavailable }
        return try JSONDecoder().decode([DYChatOption].self, from: data)
    }

    static func performOption(_ option: DYChatOption, web: WKWebView, id: String) async throws {
        let result = try await web.callAsyncJavaScript(helpersJS + performOptionJS,
            arguments: ["id": id, "optionID": option.id, "title": option.title], contentWorld: .page)
        guard result as? Bool == true else { throw BridgeError.unavailable }
    }

    static func closeOptions(_ web: WKWebView, id: String) async {
        _ = try? await web.callAsyncJavaScript(helpersJS + """
        if (window.__ddNativeChatID === id && document.querySelector('[class*="conversationConversationInfoopen"]')) {
            invoke(document.getElementById('ei-conversation-header-title-bar'));
        }
        window.__ddChatOptions = null;
        """, arguments: ["id": id], contentWorld: .page)
    }

    static func change(_ row: DYConversationRow, action: Action, web: WKWebView) async throws {
        let result = try await web.callAsyncJavaScript(helpersJS + conversationActionJS,
            arguments: ["id": row.id, "name": row.name, "avatar": row.avatar ?? "",
                        "stranger": row.stranger, "action": action.rawValue], contentWorld: .page)
        guard result as? Bool == true else { throw BridgeError.unavailable }
    }

    static let snapshotJS = #"""
    (() => {
      const header = document.querySelector('[class*="RightPanelHeaderconvHeader"]');
      if (!header || !window.__ddNativeChatID) return null;
      const streak = header.querySelector('[class*="commonStreakstreakContainer"]');
      const input = document.querySelector('[class*="messageMsgInputinputRow"]');
      const r = input?.getBoundingClientRect();
      if (r?.height > 0) document.documentElement.style.setProperty('--dd-composer-inset', (innerHeight-r.top+16)+'px');
      return JSON.stringify({
        id: window.__ddNativeChatID,
        streak: streak ? {text: streak.textContent.trim(), icon: streak.querySelector('img')?.src || null} : null
      });
    })()
    """#

    static let helpersJS = #"""
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const props = e => e && e[Object.keys(e).find(k => k.startsWith('__reactProps'))];
    const invoke = (e, event = 'onClick') => {
      if (!e) return false;
      const handler = props(e)?.[event];
      if (typeof handler === 'function') {
        handler({target:e,currentTarget:e,button:event === 'onContextMenu' ? 2 : 0,
          clientX:24,clientY:100,pageX:24,pageY:100,
          stopPropagation(){},preventDefault(){},nativeEvent:{stopImmediatePropagation(){},preventDefault(){}}});
        return true;
      }
      if (event === 'onClick') { e.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true})); return true; }
      e.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true,button:2,clientX:24,clientY:100}));
      return true;
    };
    const optionRows = () => [...document.querySelectorAll('[class*="conversationConversationInfoopen"] [class*="ConversationInfoConversationInfoItemitemContainer"]')];
    const optionTitle = e => e.querySelector('[class*="ConversationInfoConversationInfoItemleftArea"]')?.textContent?.trim() || '';
    """#

    static let optionsJS = #"""
    if (window.__ddNativeChatID !== id) return null;
    if (!document.querySelector('[class*="conversationConversationInfoopen"]')) {
      if (!invoke(document.getElementById('ei-conversation-header-title-bar'))) return null;
    }
    for (let i=0; i<15 && !optionRows().length; i++) await sleep(100);
    if (window.__ddNativeChatID !== id) return null;
    const map = new Map();
    const rows = optionRows().map((e,index) => {
      const title = optionTitle(e);
      const key = index + ':' + title;
      const control = e.querySelector('input[role="switch"], input[type="checkbox"]');
      map.set(key,e);
      return {id:key,title,checked:control ? control.checked : null,
        disabled:!!(control?.disabled || control?.getAttribute('aria-disabled') === 'true')};
    }).filter(r=>r.title);
    window.__ddChatOptions = {id,rows:map};
    return JSON.stringify(rows);
    """#

    static let performOptionJS = #"""
    const state = window.__ddChatOptions;
    if (window.__ddNativeChatID !== id || state?.id !== id) return false;
    const row = state.rows.get(optionID);
    if (!row?.isConnected || optionTitle(row) !== title) return false;
    const control = row.querySelector('input[role="switch"], input[type="checkbox"]');
    if (control) {
      if (control.disabled || control.getAttribute('aria-disabled') === 'true') return false;
      const before = control.checked;
      control.click();
      for (let i=0; i<20; i++) {
        await sleep(100);
        if (window.__ddNativeChatID !== id) return false;
        const current = optionRows().find(e=>optionTitle(e) === title)?.querySelector('input[role="switch"], input[type="checkbox"]');
        if (current && current.checked !== before) return true;
      }
      return false;
    }
    const target = [row,...row.querySelectorAll('*')].find(e=>typeof props(e)?.onClick === 'function');
    return target ? invoke(target) : false;
    """#

    static let conversationActionJS = #"""
    const conversationOf = e => {
      let f=e[Object.keys(e).find(k=>k.startsWith('__reactFiber'))];
      for(let i=0;f && i<8;i++,f=f.return) if(f.memoizedProps?.conversation) return f.memoizedProps.conversation;
      return null;
    };
    const matches = e => {
      if (!!e.closest('[class*="StrangerConversationList"]') !== stranger) return false;
      const c=conversationOf(e);
      if (id.startsWith('conversation:')) return c && 'conversation:'+c.id === id;
      return e.querySelector('[class="conversationConversationItemtitle"]')?.textContent?.trim() === name
        && (!avatar || e.querySelector('img')?.src === avatar);
    };
    const find = () => {
      const rows=[...document.querySelectorAll('[data-e2e="conversation-item"]')].filter(matches);
      return rows.length === 1 ? rows[0] : null;
    };
    const wrap = document.querySelector(stranger ? '[class*="StrangerConversationListlistWrapper"]' : '[class*="ConversationListwrapper"]');
    const scroll = wrap && [wrap,...wrap.querySelectorAll('div')].find(e=>e.scrollHeight>e.clientHeight+5);
    const oldScroll = scroll?.scrollTop;
    const scope = window.__ddAccountScope;
    let menu;
    document.documentElement.dataset.ddRowAction = 'true';
    try {
      let row=find();
      if (!row && scroll) {
        scroll.scrollTop=0;scroll.dispatchEvent(new Event('scroll',{bubbles:true}));
        for(let i=0;i<40 && !row;i++) {
          await sleep(150); row=find();
          if(row || scroll.scrollTop+scroll.clientHeight>=scroll.scrollHeight-2) break;
          scroll.scrollTop+=Math.max(200,scroll.clientHeight*0.8);
          scroll.dispatchEvent(new Event('scroll',{bubbles:true}));
        }
      }
      if (!row || window.__ddAccountScope !== scope) return false;
      const pinned=String(row.className).includes('isStickOnTop');
      if(action === 'pin' && pinned || action === 'unpin' && !pinned) return true;
      invoke(row,'onContextMenu');
      const wanted = action === 'pin' ? ['置顶','置顶聊天'] : action === 'unpin' ? ['取消置顶','取消置顶聊天'] : ['删除','删除会话','删除聊天'];
      for(let i=0;i<10 && !menu;i++) {
        await sleep(100);
        menu=[...document.querySelectorAll('[class*="ConversationItemMenumenuItem"],[role="menuitem"],.semi-dropdown-item')]
          .find(e=>wanted.includes(e.textContent.trim()));
      }
      if (!menu || !row.isConnected || !matches(row) || window.__ddAccountScope !== scope) return false;
      invoke(menu);
      if (action === 'delete') {
        // Only confirm the deletion requested by the native confirmation alert.
        for(let i=0;i<8;i++) {
          await sleep(100);
          const dialog=[...document.querySelectorAll('[role="dialog"],.semi-modal-content')].find(e=>/删除/.test(e.textContent));
          const confirm=dialog && [...dialog.querySelectorAll('button')].find(e=>['删除','确定','确认'].includes(e.textContent.trim()));
          if(confirm){invoke(confirm);break;}
          if(!find()) break;
        }
      }
      for(let i=0;i<25;i++) {
        await sleep(100);
        if(window.__ddAccountScope !== scope) return false;
        const current=find();
        if(action === 'delete' ? !current : current && String(current.className).includes('isStickOnTop') === (action === 'pin')) return true;
      }
      return false;
    } finally {
      document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
      delete document.documentElement.dataset.ddRowAction;
      if(scroll && oldScroll !== undefined) {scroll.scrollTop=oldScroll;scroll.dispatchEvent(new Event('scroll',{bubbles:true}));}
    }
    """#
}
