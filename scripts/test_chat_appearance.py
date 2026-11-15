#!/usr/bin/env python3
"""Render production CSS against measured IM shell classes; no network or account actions."""
import html as html_module
import json, pathlib, re, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
source = (ROOT/'DouDuo/DouyinMessages.swift').read_text()
match = re.search(r'static let chatChromeCSS = #"""\n(.*?)\n\s*"""#', source, re.S)
assert match, 'RED: unified chat appearance stylesheet is missing'
css = match.group(1)
theme = (ROOT/'DouDuo/Theme.swift').read_text()
for placeholder, key in [('__DD_CHAT_CANVAS__','canvasCSS'), ('__DD_CHAT_SEPARATOR__','separatorCSS')]:
    color = re.search(r'let '+key+r' = "([^"]+)"', theme)
    assert color, 'missing theme token '+key
    css = css.replace(placeholder, color.group(1))
assert '__DD_CHAT_' not in css
# Names and nesting are from the real read-only WKWebView layout capture.
html = '''<!doctype html><meta charset="utf-8"><style>
html,body{margin:0}body{min-width:628px}.chatDark{position:fixed;inset:0;background:#161616}
.componentsEntrywrapper{display:flex;width:100%;height:100%;background:#252632}
.componentsRightPanelwrapper{display:flex;flex-direction:column;overflow:hidden;flex:1}
.RightPanelHeaderconvHeader{height:60px}
.componentsRightPanelnotHeaderArea{display:flex;flex-direction:column;flex:1;overflow:hidden}
.messageMessageListwrapper{overflow:hidden;flex:1}.messageMessageListlist{height:100%;overflow-y:scroll}
.componentsRightPanelinputArea{height:76px}button{display:inline-block}
</style><style>CSS</style>
<div class="chatDark"><div class="componentsEntrywrapper"><div class="semi-resizable-resizable">web sidebar</div>
<div class="componentsRightPanelwrapper"><div class="RightPanelHeaderconvHeader"><button id="menu">menu</button></div>
<div class="componentsRightPanelnotHeaderArea"><div class="messageMessageListwrapper"><div class="messageMessageListlist"><div style="height:1800px">layout fixture, not real messages</div></div></div>
<div class="componentsRightPanelinputArea"><input placeholder="composer"><button id="send">send</button></div></div></div></div></div>
<script>const q=s=>document.querySelector(s), rect=s=>{let r=q(s).getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height,bottom:r.bottom}};
let list=q('.messageMessageListlist');list.scrollTop=400;
let result={vw:innerWidth,vh:innerHeight,shell:rect('.componentsEntrywrapper'),panel:rect('.componentsRightPanelwrapper'),input:rect('.componentsRightPanelinputArea'),list:rect('.messageMessageListlist'),scroll:list.scrollTop,bg:getComputedStyle(q('.componentsEntrywrapper')).backgroundColor,menu:getComputedStyle(q('#menu')).display,send:getComputedStyle(q('#send')).display};
parent.postMessage(result,'*');</script>'''.replace('CSS', css)
scratch=pathlib.Path('/Users/zhanghongsheng/.hermes/profiles/shayu/cache/scratch')
with tempfile.TemporaryDirectory(prefix='chat-css-', dir=scratch) as d:
    p=pathlib.Path(d)/'fixture.html'
    for width,height in [(382,720),(620,760)]:
        # Chrome's top-level window has a minimum width; use an exact-size iframe
        # so the narrow case really renders at 382 CSS px, not a silent 500px clamp.
        p.write_text('<!doctype html><pre id="result"></pre><script>onmessage=e=>document.querySelector("pre").textContent=JSON.stringify(e.data)</script>'
                     +f'<iframe style="border:0;width:{width}px;height:{height}px" srcdoc="{html_module.escape(html, quote=True)}"></iframe>')
        r=subprocess.run(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','--headless=new','--disable-gpu','--no-sandbox','--no-proxy-server',f'--user-data-dir={d}/chrome-{width}','--window-size=1000,1000','--virtual-time-budget=1000','--dump-dom',p.as_uri()],capture_output=True,text=True,timeout=45,check=True)
        m=re.search(r'<pre id="result">(.*?)</pre>',r.stdout,re.S);assert m,r.stderr[-1500:]
        v=json.loads(m.group(1))
        assert v['vw']==width and v['vh']==height,v
        assert abs(v['shell']['w']-v['vw'])<1,v
        assert abs(v['panel']['w']-v['vw'])<1,v
        assert abs(v['shell']['h']-v['vh'])<1,v
        assert abs(v['input']['bottom']-v['vh'])<1,v
        assert v['list']['h']>100 and v['scroll']==400,v
        assert v['bg']=='rgb(0, 0, 0)',v
        assert v['menu']!='none' and v['send']!='none',v
        print('PASS CSS viewport',v['vw'],v['vh'],'full-height shell, shared canvas, scroll and composer preserved')
