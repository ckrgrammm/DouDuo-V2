#!/usr/bin/env python3
"""Compile the production, Foundation-only navigation state without UIKit/network."""
import os, pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
source = root / 'DouDuo/DYMessageNavigation.swift'
assert source.exists(), 'RED: unified message detail navigation is not implemented'
swift = '''
enum DYMsgRoute: Hashable { case interactive, fans, system, stranger }
@main struct NavigationTests {
 static func main() {
  var n = DYMessageNavigation()
  precondition(!n.hasDetail)
  n.select(.interactive)
  precondition(n.category == .interactive && n.hasDetail && !n.isChat)
  n.select(.fans)
  precondition(n.category == .fans && !n.isChat)
  n.openChat("friend", from: nil)
  precondition(n.isChat && n.category == nil)
  precondition(!n.back() && !n.hasDetail)
  precondition(n.back()) // only root closes the message center
  n.select(.stranger)
  n.openChat("stranger-person", from: .stranger)
  precondition(n.isChat && n.category == .stranger)
  precondition(!n.back() && n.category == .stranger && !n.isChat)
  precondition(!n.back() && !n.hasDetail)
  n.openChat("friend", from: nil)
  n.select(.system)
  precondition(!n.isChat && n.category == .system)
  print("PASS navigation: category switching, chat selection, stranger parent, layered back, root close")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='message-navigation-', dir=os.environ['TMPDIR']) as d:
    p=pathlib.Path(d); (p/'Tests.swift').write_text(swift)
    subprocess.run(['swiftc', str(source), str(p/'Tests.swift'), '-o', str(p/'tests')],check=True)
    subprocess.run([str(p/'tests')],check=True)
