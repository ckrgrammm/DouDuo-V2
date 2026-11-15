import Foundation
import WebKit
import SwiftUI

/// Foreground DM monitoring. Off unless the user turns on in-app notifications.
enum DYDMProbe {
    static var enabled: Bool { DYDMNotificationSettings.notificationsOn && !blocksFixture }
    /// Direct opening uses the same user switch. It does not reveal sender identity.
    static var directEnabled: Bool { enabled }
    #if DEBUG
    /// Development-only. Release builds never report message shape.
    static var shapeEnabled: Bool {
        enabled && ProcessInfo.processInfo.environment["DOUDUO_DM_SHAPE"] == "1"
    }
    #else
    static var shapeEnabled: Bool { false }
    #endif
    static var blocksFixture: Bool {
        #if DEBUG
        DYMessageFixture.enabled
        #else
        false
        #endif
    }
}

// BEGIN DYDMProbeGate
enum DYDMProbeGate {
    static let maxBytes = 512
    static let maxPerSecond = 4
    static let trustedHosts: Set<String> = ["www.douyin.com"]
    private static let sources: Set<String> = ["obs", "poll"]
    private static let keys: Set<String> = [
        "type", "v", "src", "seq", "gen", "epoch", "baseline", "incoming", "outgoing",
        "reorder", "badge", "rebuild", "activity", "visible", "hidden", "ready", "obs", "lag"
    ]

    struct Input: Equatable {
        var body: String
        var scheme: String?
        var host: String?
        var port: Int
        var generation: Int
        var epoch: Int
        var lastSeq: Int
        var recentCount: Int
        var requireOrigin: Bool
        var acceptShape: Bool
        var acceptRoute: Bool
    }

    struct Event: Equatable {
        var src: String
        var seq: Int
        var baseline: Int
        var incoming: Int
        var outgoing: Int
        var reorder: Int
        var badge: Int
        var rebuild: Int
        var activity: Int
        var visible: Int
        var hidden: Int
        var ready: Int
        var observer: Int
        var lagMs: Int
        var aliasOnly: Bool
        var directReady: Bool
        var faceKind: Int
        var faceName: String
        var faceAvatar: String
    }

    struct DiagnosticChange: Equatable {
        var slot: Int
        var relation: String
        var oldSource: String
        var newSource: String
        var direction: String
    }

    struct Diagnostic: Equatable {
        var eventSeq: Int
        var rows: Int
        var count: Int
        var truncated: Int
        var changes: [DiagnosticChange]
    }

    enum Verdict: Equatable {
        case forward
        case drop(String)
        case event(Event)
        case diagnostic(Diagnostic)
        case shape(Shape)
        case route(Route)
    }

    struct Route: Equatable {
        var eventSeq: Int
        var id: String
    }

    struct Shape: Equatable {
        var eventSeq: Int
        var message: Int
        var identifier: Int
        var direction: Int
        var alias: Int
        var multiple: Int
        var sameObject: Int
        var withheld: Int
        var content: Int
        var parsed: Int
        var text: Int
        var inner: Int
        var parsedText: Int
        var awe: Int
        var messageType: Int
        var status: Int
        var recall: Int
    }

    static func isProbeBody(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8) else { return false }
        if data.count > maxBytes {
            let head = body.prefix(96)
            return head.contains("\"type\":\"dm-probe\"") || head.contains("\"type\": \"dm-probe\"")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["type"] as? String == "dm-probe"
    }

    static func isDiagBody(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8) else { return false }
        if data.count > maxBytes {
            let head = body.prefix(96)
            return head.contains("\"type\":\"dm-probe-diag\"") || head.contains("\"type\": \"dm-probe-diag\"")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["type"] as? String == "dm-probe-diag"
    }

    static func isShapeBody(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8) else { return false }
        if data.count > maxBytes {
            let head = body.prefix(96)
            return head.contains("\"type\":\"dm-probe-shape\"") || head.contains("\"type\": \"dm-probe-shape\"")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["type"] as? String == "dm-probe-shape"
    }

    static func isRouteBody(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8) else { return false }
        if data.count > maxBytes {
            let head = body.prefix(96)
            return head.contains("\"type\":\"dm-probe-route\"") || head.contains("\"type\": \"dm-probe-route\"")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["type"] as? String == "dm-probe-route"
    }

    static func verdict(_ input: Input) -> Verdict {
        if isRouteBody(input.body) { return routeVerdict(input) }
        if isShapeBody(input.body) { return shapeVerdict(input) }
        if isDiagBody(input.body) { return diagnosticVerdict(input) }
        guard isProbeBody(input.body) else { return .forward }
        guard let data = input.body.data(using: .utf8), data.count <= maxBytes,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .drop("size") }
        let extra = Set(obj.keys).subtracting(keys)
        guard extra.isSubset(of: ["alias", "face", "direct"]), integer(obj, "v") == 1,
              let src = obj["src"] as? String, sources.contains(src) else { return .drop("schema") }
        guard let seq = integer(obj, "seq"), seq > 0, seq < 2_000_000_000 else { return .drop("schema-seq") }
        guard seq > input.lastSeq else { return .drop("duplicate") }
        guard let gen = integer(obj, "gen"), gen == input.generation, gen > 0 else { return .drop("gen") }
        guard let epoch = integer(obj, "epoch"), epoch == input.epoch, epoch > 0 else { return .drop("epoch") }
        if input.requireOrigin {
            let scheme = input.scheme?.lowercased()
            let host = input.host?.lowercased()
            guard scheme == "https", let host, trustedHosts.contains(host), input.port == 0 || input.port == 443 else {
                return .drop("origin")
            }
        }
        guard input.recentCount < maxPerSecond else { return .drop("rate") }
        guard let baseline = flag(obj, "baseline"),
              let incoming = count(obj, "incoming"),
              let outgoing = count(obj, "outgoing"),
              let reorder = count(obj, "reorder"),
              let badge = count(obj, "badge"),
              let rebuild = count(obj, "rebuild"),
              let activity = count(obj, "activity"),
              let visible = integer(obj, "visible"), (0...500).contains(visible),
              let hidden = flag(obj, "hidden"),
              let ready = flag(obj, "ready"),
              let observer = integer(obj, "obs"), (0...1_000_000).contains(observer),
              let lag = integer(obj, "lag"), (0...60_000).contains(lag) else { return .drop("schema") }
        if baseline == 1 && (incoming + outgoing + reorder + badge + rebuild + activity) != 0 { return .drop("schema") }
        if extra.contains("alias"), flag(obj, "alias") != 1 { return .drop("schema") }
        if extra.contains("direct"), flag(obj, "direct") != 1 { return .drop("schema") }
        let identity = acceptedFace(obj["face"])
        return .event(Event(src: src, seq: seq, baseline: baseline, incoming: incoming, outgoing: outgoing,
                             reorder: reorder, badge: badge, rebuild: rebuild, activity: activity, visible: visible,
                             hidden: hidden, ready: ready, observer: observer, lagMs: lag,
                             aliasOnly: extra.contains("alias"), directReady: extra.contains("direct"),
                             faceKind: identity?.kind ?? 0, faceName: identity?.name ?? "", faceAvatar: identity?.avatar ?? ""))
    }

    private static func acceptedFace(_ raw: Any?) -> (kind: Int, name: String, avatar: String)? {
        guard let face = raw as? [String: Any], Set(face.keys) == ["kind", "name", "avatar"],
              let kind = integer(face, "kind"), kind == 1 || kind == 2,
              let name = face["name"] as? String,
              let avatar = face["avatar"] as? String else { return nil }
        return (kind, name, avatar)
    }

    private static func integer(_ obj: [String: Any], _ key: String) -> Int? {
        guard let value = obj[key] as? NSNumber else { return nil }
        // NSNumber bridges to Bool, so `is Bool` cannot separate JSON true from JSON 1.
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        return numberValue(value)
    }

    private static func numberValue(_ value: NSNumber) -> Int { value.intValue }

    private static func flag(_ obj: [String: Any], _ key: String) -> Int? {
        guard let value = integer(obj, key), value == 0 || value == 1 else { return nil }
        return value
    }

    private static let diagnosticKeys: Set<String> = ["type", "v", "eventSeq", "rows", "n", "truncated", "gen", "epoch", "changes"]
    private static let changeKeys: Set<String> = ["slot", "rel", "old", "new", "dir"]
    private static let relations: Set<String> = ["alias-overlap", "unlinked-change"]
    private static let identitySources: Set<String> = ["serverId", "clientId", "id", "missing"]
    private static let directions: Set<String> = ["incoming", "outgoing", "unknown"]

    static func diagnosticVerdict(_ input: Input) -> Verdict {
        guard isDiagBody(input.body) else { return .forward }
        guard let data = input.body.data(using: .utf8), data.count <= maxBytes,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .drop("size") }
        guard Set(obj.keys) == diagnosticKeys, integer(obj, "v") == 1 else { return .drop("schema") }
        guard let eventSeq = integer(obj, "eventSeq"), eventSeq > 0, eventSeq < 2_000_000_000 else { return .drop("schema") }
        guard let gen = integer(obj, "gen"), gen == input.generation, gen > 0 else { return .drop("gen") }
        guard let epoch = integer(obj, "epoch"), epoch == input.epoch, epoch > 0 else { return .drop("epoch") }
        if input.requireOrigin {
            let scheme = input.scheme?.lowercased()
            let host = input.host?.lowercased()
            guard scheme == "https", let host, trustedHosts.contains(host), input.port == 0 || input.port == 443 else {
                return .drop("origin")
            }
        }
        guard let rows = integer(obj, "rows"), (0...500).contains(rows),
              let count = integer(obj, "n"), (1...30).contains(count),
              let truncated = flag(obj, "truncated"),
              let rawChanges = obj["changes"] as? [Any], !rawChanges.isEmpty, rawChanges.count <= 3,
              truncated == 1 || rawChanges.count == count,
              truncated == 0 || count >= rawChanges.count else { return .drop("schema") }
        var changes: [DiagnosticChange] = []
        for raw in rawChanges {
            guard let change = raw as? [String: Any], Set(change.keys) == changeKeys,
                  let slot = integer(change, "slot"), (1...100_000).contains(slot),
                  let relation = change["rel"] as? String, relations.contains(relation),
                  let oldSource = change["old"] as? String, identitySources.contains(oldSource),
                  let newSource = change["new"] as? String, identitySources.contains(newSource),
                  let direction = change["dir"] as? String, directions.contains(direction) else { return .drop("schema") }
            changes.append(DiagnosticChange(slot: slot, relation: relation, oldSource: oldSource, newSource: newSource, direction: direction))
        }
        return .diagnostic(Diagnostic(eventSeq: eventSeq, rows: rows, count: count, truncated: truncated, changes: changes))
    }

    private static let shapeKeys: Set<String> = [
        "type", "v", "eventSeq", "gen", "epoch", "msg", "id", "dir", "alias", "multi", "same", "hold",
        "content", "parsed", "text", "inner", "ptext", "awe", "kind", "status", "recall"
    ]

    static func shapeVerdict(_ input: Input) -> Verdict {
        guard isShapeBody(input.body), input.acceptShape else { return .forward }
        guard let data = input.body.data(using: .utf8), data.count <= maxBytes,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .drop("size") }
        guard Set(obj.keys) == shapeKeys, integer(obj, "v") == 1 else { return .drop("schema") }
        guard let eventSeq = integer(obj, "eventSeq"), eventSeq > 0, eventSeq < 2_000_000_000 else { return .drop("schema") }
        guard let gen = integer(obj, "gen"), gen == input.generation, gen > 0 else { return .drop("gen") }
        guard let epoch = integer(obj, "epoch"), epoch == input.epoch, epoch > 0 else { return .drop("epoch") }
        if input.requireOrigin {
            let scheme = input.scheme?.lowercased()
            let host = input.host?.lowercased()
            guard scheme == "https", let host, trustedHosts.contains(host), input.port == 0 || input.port == 443 else {
                return .drop("origin")
            }
        }
        guard let message = flag(obj, "msg"),
              let identifier = flag(obj, "id"),
              let direction = integer(obj, "dir"), (0...2).contains(direction),
              let alias = flag(obj, "alias"),
              let multiple = flag(obj, "multi"),
              let sameObject = flag(obj, "same"),
              let withheld = flag(obj, "hold"),
              let content = typeCode(obj, "content"),
              let parsed = typeCode(obj, "parsed"),
              let text = typeCode(obj, "text"),
              let inner = typeCode(obj, "inner"),
              let parsedText = typeCode(obj, "ptext"),
              let awe = typeCode(obj, "awe"),
              let messageType = typeCode(obj, "kind"),
              let status = typeCode(obj, "status"),
              let recall = typeCode(obj, "recall") else { return .drop("schema") }
        return .shape(Shape(eventSeq: eventSeq, message: message, identifier: identifier, direction: direction,
                             alias: alias, multiple: multiple, sameObject: sameObject, withheld: withheld,
                             content: content, parsed: parsed, text: text, inner: inner, parsedText: parsedText,
                             awe: awe, messageType: messageType, status: status, recall: recall))
    }

    private static let routeKeys: Set<String> = ["type", "v", "eventSeq", "gen", "epoch", "id"]

    static func routeVerdict(_ input: Input) -> Verdict {
        guard isRouteBody(input.body), input.acceptRoute else { return .forward }
        guard let data = input.body.data(using: .utf8), data.count <= maxBytes,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .drop("size") }
        guard Set(obj.keys) == routeKeys, integer(obj, "v") == 1 else { return .drop("schema") }
        guard let eventSeq = integer(obj, "eventSeq"), eventSeq > 0, eventSeq < 2_000_000_000 else { return .drop("schema") }
        guard let gen = integer(obj, "gen"), gen == input.generation, gen > 0 else { return .drop("gen") }
        guard let epoch = integer(obj, "epoch"), epoch == input.epoch, epoch > 0 else { return .drop("epoch") }
        if input.requireOrigin {
            let scheme = input.scheme?.lowercased()
            let host = input.host?.lowercased()
            guard scheme == "https", let host, trustedHosts.contains(host), input.port == 0 || input.port == 443 else {
                return .drop("origin")
            }
        }
        guard let id = obj["id"] as? String, Self.acceptableRoute(id) else { return .drop("schema") }
        return .route(Route(eventSeq: eventSeq, id: id))
    }

    static func acceptableRoute(_ id: String) -> Bool {
        guard (1...80).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { $0.value >= 32 && !$0.properties.isWhitespace }
    }

    private static func typeCode(_ obj: [String: Any], _ key: String) -> Int? {
        guard let value = integer(obj, key), (0...6).contains(value) else { return nil }
        return value
    }

    private static func count(_ obj: [String: Any], _ key: String) -> Int? {
        guard let value = integer(obj, key), (0...30).contains(value) else { return nil }
        return value
    }
}
// END DYDMProbeGate

enum DYDMProbeScript {
    static let collectJS = #"""
    function __ddDMToken(item) { return item.messageID + '\t' + item.badge + '\t' + item.dir; }
    function __ddDMDirection(message) {
      if (!message) return 'unknown';
      for (const key of ['isFromMe', 'fromMe', 'isSelf']) {
        if (typeof message[key] === 'boolean') return message[key] ? 'out' : 'in';
      }
      return 'unknown';
    }
    function __ddDMRead() {
      const inStranger = e => !!e.closest('[class*="StrangerConversationList"]');
      const badgeOf = e => {
        const b = e.querySelector('[class*="UnReadCount"].semi-badge, [class*="digitsNumber"], [class*="badge-count"]');
        if (b && b.textContent.trim()) return b.textContent.trim();
        return e.querySelector('[class*="UnReadCount"], [class*="badge-dot"]') ? '1' : '0';
      };
      const convOf = e => {
        const k = Object.keys(e).find(key => key.startsWith('__reactFiber'));
        let f = k ? e[k] : null;
        for (let i = 0; f && i < 6; i++, f = f.return) if (f.memoizedProps && f.memoizedProps.conversation) return f.memoizedProps.conversation;
        return null;
      };
      const text = value => value == null || value === '' ? '' : String(value);
      const identify = message => {
        const serverId = text(message && message.serverId);
        const clientId = text(message && message.clientId);
        const bare = text(message && message.id);
        let messageID = '', source = 'missing';
        if (serverId) { messageID = serverId; source = 'serverId'; }
        else if (clientId) { messageID = clientId; source = 'clientId'; }
        else if (bare) { messageID = bare; source = 'id'; }
        return { messageID, source, serverId, clientId, bare };
      };
      const wrap = document.querySelector('[class*="ConversationListwrapper"]');
      if (!wrap) return null;
      return [...document.querySelectorAll('[data-e2e="conversation-item"]')].filter(e => !inStranger(e)).map(e => {
        const c = convOf(e);
        if (!c || typeof c.id !== 'string' || !c.id) return null;
        const last = c.lastVisibleMessage || c.lastMessage || null;
        const titleNode = e.querySelector('[class="conversationConversationItemtitle"]');
        const title = titleNode && titleNode.textContent ? titleNode.textContent.trim() : '';
        const image = e.querySelector('img');
        const record = Object.assign({ id: 'c:' + c.id, badge: badgeOf(e), dir: __ddDMDirection(last),
          title, avatar: image && image.src ? String(image.src) : '', kind: Number(c.type) }, identify(last));
        if (globalThis.__ddDMShape === 1 && typeof WeakMap === 'function') {
          if (!(globalThis.__ddDMShapes instanceof WeakMap)) globalThis.__ddDMShapes = new WeakMap();
          globalThis.__ddDMShapes.set(record, last || null);
        }
        return record;
      }).filter(Boolean);
    }
    function __ddDMPack(item) { return item.source + '\u0001' + __ddDMToken(item); }
    function __ddDMUnpack(stored) {
      if (stored == null) return { token: null, source: 'missing' };
      const sep = stored.indexOf('\u0001');
      if (sep < 0) return { token: stored, source: 'missing' };
      const source = stored.slice(0, sep);
      const allowed = source === 'serverId' || source === 'clientId' || source === 'id' || source === 'missing';
      return { token: stored.slice(sep + 1), source: allowed ? source : 'missing' };
    }
    function __ddDMSlot(s, convId) {
      if (!(s.slots instanceof Map)) s.slots = new Map();
      if (!Number.isFinite(s.nextSlot) || s.nextSlot < 1) s.nextSlot = 1;
      let slot = s.slots.get(convId);
      if (slot == null) { slot = s.nextSlot; s.nextSlot += 1; s.slots.set(convId, slot); }
      return slot;
    }
    function __ddDMRelation(previousSelected, item) {
      if (previousSelected && (previousSelected === item.serverId || previousSelected === item.clientId || previousSelected === item.bare)) return 'alias-overlap';
      return 'unlinked-change';
    }
    function __ddDMDirLabel(dir) { return dir === 'in' ? 'incoming' : dir === 'out' ? 'outgoing' : 'unknown'; }
    function __ddDMStageDiag(s, rows, changes) {
      const shown = changes.slice(0, 3);
      const payload = {
        type: 'dm-probe-diag', v: 1, eventSeq: s.seq, rows: Math.min(rows, 500),
        n: Math.min(changes.length, 30), truncated: changes.length > shown.length ? 1 : 0,
        gen: globalThis.__ddDMGen | 0, epoch: globalThis.__ddDMEpoch | 0, changes: shown
      };
      const text = JSON.stringify(payload);
      globalThis.__ddDMPendingDiag = text.length <= 512 ? text : null;
    }
    function __ddDMState() {
      const s = globalThis.__ddDM || (globalThis.__ddDM = {});
      if (!Number.isFinite(s.seq) || s.seq < 0) s.seq = 0;
      if (!(s.rows instanceof Map)) s.rows = new Map();
      if (!Array.isArray(s.order)) s.order = [];
      if (!Number.isFinite(s.obs) || s.obs < 0) s.obs = 0;
      if (!Number.isFinite(s.suppressed) || s.suppressed < 0) s.suppressed = 0;
      if (typeof s.armed !== 'boolean') s.armed = false;
      if (typeof s.rebuilding !== 'boolean') s.rebuilding = false;
      if (!Number.isFinite(s.mutated)) s.mutated = 0;
      if (!(s.slots instanceof Map)) s.slots = new Map();
      if (!Number.isFinite(s.nextSlot) || s.nextSlot < 1) s.nextSlot = 1;
      globalThis.__ddDM = s;
      return s;
    }
    function __ddDMNextSeq(s) {
      if (!Number.isFinite(s.seq) || s.seq < 0) s.seq = 0;
      s.seq += 1;
      return s.seq;
    }
    function __ddDMSeqOk(seq) { return Number.isFinite(seq) && seq > 0 && seq < 2000000000; }
    function __ddDMPrepareEpoch() {
      const s = __ddDMState();
      s.armed = false;
      s.rows = new Map();
      s.order = [];
      s.rebuilding = false;
      s.slots = new Map();
      s.nextSlot = 1;
      globalThis.__ddDMPendingDiag = null;
      globalThis.__ddDMPendingShape = null;
      globalThis.__ddDMPendingRoute = null;
      globalThis.__ddDMShapes = null;
      return 1;
    }
    function __ddDMStageRoute(s, change) {
      const stored = change && change.item ? String(change.item.id || '') : '';
      if (!stored.startsWith('c:')) return false;
      const id = stored.slice(2);
      if (!id || id.length > 80 || /[\u0000-\u001f\s]/.test(id)) return false;
      const body = {
        type: 'dm-probe-route', v: 1, eventSeq: s.seq,
        gen: globalThis.__ddDMGen | 0, epoch: globalThis.__ddDMEpoch | 0, id
      };
      const text = JSON.stringify(body);
      if (text.length > 512) return false;
      globalThis.__ddDMPendingRoute = text;
      return true;
    }
    function __ddDMKind(value) {
      if (value === undefined) return 0;
      if (value === null) return 6;
      switch (typeof value) {
        case 'boolean': return 1;
        case 'number': return 2;
        case 'string': return 3;
        case 'object': return 4;
        case 'function': return 5;
        default: return 6;
      }
    }
    function __ddDMShapeOf(message) {
      const blank = { msg: 0, id: 0, dir: 0, content: 0, parsed: 0, text: 0, inner: 0, ptext: 0, awe: 0, kind: 0, status: 0, recall: 0 };
      if (!message || typeof message !== 'object') return blank;
      const present = value => !(value == null || value === '');
      const direction = __ddDMDirection(message);
      let inner = 0, awe = 0;
      const content = message.content;
      if (typeof content === 'string') {
        try {
          const parsed = JSON.parse(content);
          if (parsed && typeof parsed === 'object') { inner = __ddDMKind(parsed.text); awe = __ddDMKind(parsed.aweType); }
          else inner = 6;
        } catch (e) { inner = 6; }
      } else if (content && typeof content === 'object') {
        inner = __ddDMKind(content.text);
        awe = __ddDMKind(content.aweType);
      }
      const parsedContent = message.parsedContent;
      let parsedText = 0;
      if (parsedContent && typeof parsedContent === 'object') {
        parsedText = __ddDMKind(parsedContent.text);
        awe = __ddDMKind(parsedContent.aweType);
      }
      const recall = message.isRecalled !== undefined ? message.isRecalled : message.recallType;
      return {
        msg: 1, id: present(message.serverId) || present(message.clientId) || present(message.id) ? 1 : 0,
        dir: direction === 'in' ? 1 : direction === 'out' ? 2 : 0,
        content: __ddDMKind(content), parsed: __ddDMKind(parsedContent), text: __ddDMKind(message.text),
        inner, ptext: parsedText, awe, kind: __ddDMKind(message.type), status: __ddDMKind(message.status),
        recall: __ddDMKind(recall)
      };
    }
    function __ddDMStageShape(s, changes) {
      const inbound = changes.filter(change => change.dir === 'incoming');
      if (!inbound.length) return;
      const multi = changes.length === 1 ? 0 : 1;
      const blank = { msg: 0, id: 0, dir: 1, content: 0, parsed: 0, text: 0, inner: 0, ptext: 0, awe: 0, kind: 0, status: 0, recall: 0 };
      let picked = blank, alias = 0, same = 0, hold = 0;
      if (multi === 0 && inbound.length === 1) {
        const message = globalThis.__ddDMShapes instanceof WeakMap ? globalThis.__ddDMShapes.get(inbound[0].item) : null;
        picked = __ddDMShapeOf(message);
        alias = inbound[0].rel === 'alias-overlap' ? 1 : 0;
        same = picked.msg === 1 ? 1 : 0;
      } else hold = 1;
      const body = {
        type: 'dm-probe-shape', v: 1, eventSeq: s.seq, gen: globalThis.__ddDMGen | 0, epoch: globalThis.__ddDMEpoch | 0,
        msg: picked.msg, id: picked.id, dir: hold ? 1 : picked.dir, alias, multi, same, hold,
        content: hold ? 0 : picked.content, parsed: hold ? 0 : picked.parsed, text: hold ? 0 : picked.text,
        inner: hold ? 0 : picked.inner, ptext: hold ? 0 : picked.ptext, awe: hold ? 0 : picked.awe,
        kind: hold ? 0 : picked.kind, status: hold ? 0 : picked.status, recall: hold ? 0 : picked.recall
      };
      const text = JSON.stringify(body);
      globalThis.__ddDMPendingShape = text.length <= 512 ? text : null;
    }
    function __ddDMAvatar(value) {
      const text = String(value || '');
      if (!text || text.length > 180) return '';
      try {
        const url = new URL(text);
        if (url.protocol !== 'https:' || url.username || url.password) return '';
        const host = url.hostname.toLowerCase();
        const ok = ['douyin.com','douyinpic.com','douyinvod.com','iesdouyin.com','amemv.com','snssdk.com','bytedance.com','zijieapi.com'];
        if (!ok.some(suffix => host === suffix || host.endsWith('.' + suffix))) return '';
        return url.toString();
      } catch (e) { return ''; }
    }
    function __ddDMDisplay(item) {
      const name = String(item.title || '').trim();
      if (!name || name.length > 40 || /[\u0000-\u001f]/.test(name)) return null;
      if (item.kind !== 1 && item.kind !== 2) return null;
      return { kind: item.kind, name, avatar: __ddDMAvatar(item.avatar) };
    }
    function __ddDMPayload(src, counts, extra) {
      const s = __ddDMState();
      if (!__ddDMSeqOk(s.seq)) return null;
      const lag = src === 'obs' ? Math.max(0, Math.min(60000, Date.now() - (s.mutated || Date.now()))) : 0;
      const body = {
        type: 'dm-probe', v: 1, src, seq: s.seq, gen: globalThis.__ddDMGen | 0, epoch: globalThis.__ddDMEpoch | 0,
        baseline: counts.baseline, incoming: Math.min(counts.incoming, 30), outgoing: Math.min(counts.outgoing, 30), reorder: Math.min(counts.reorder, 30),
        badge: Math.min(counts.badge, 30), rebuild: Math.min(counts.rebuild, 30), activity: Math.min(counts.activity, 30), visible: Math.min(counts.visible, 500),
        hidden: document.hidden ? 1 : 0, ready: document.readyState === 'complete' ? 1 : 0, obs: Math.min(s.obs | 0, 1000000), lag
      };
      if (extra && extra.alias) body.alias = 1;
      if (extra && extra.direct) body.direct = 1;
      if (extra && extra.face) body.face = extra.face;
      let text = JSON.stringify(body);
      if (text.length > 480 && body.face) { body.face = { kind: body.face.kind, name: body.face.name, avatar: '' }; text = JSON.stringify(body); }
      if (text.length > 480) { delete body.face; text = JSON.stringify(body); }
      return text;
    }
    function __ddDMCollect(src) {
      globalThis.__ddDMPendingShape = null;
      globalThis.__ddDMPendingRoute = null;
      const gen = globalThis.__ddDMGen | 0, epoch = globalThis.__ddDMEpoch | 0;
      if (!gen || !epoch) return null;
      globalThis.__ddDMPendingDiag = null;
      const s = __ddDMState();
      const done = value => { globalThis.__ddDMShapes = null; return value; };
      const items = __ddDMRead();
      if (!items) return done(null);
      if (!s.armed) {
        if (items.length === 0) return done(null);
        const seq = __ddDMNextSeq(s);
        if (!__ddDMSeqOk(seq)) { s.seq = 0; return done(null); }
        s.rebuilding = false;
        s.rows = new Map(items.map(item => [item.id, __ddDMPack(item)]));
        s.order = items.map(item => item.id);
        s.armed = true;
        return done(__ddDMPayload(src, { baseline: 1, incoming: 0, outgoing: 0, reorder: 0, badge: 0, rebuild: 0, activity: 0, visible: items.length }));
      }
      if (items.length === 0 && s.order.length) {
        if (s.rebuilding) { s.suppressed += 1; return done(null); }
        const seq = __ddDMNextSeq(s);
        if (!__ddDMSeqOk(seq)) { s.seq = 0; s.armed = false; return done(null); }
        s.rebuilding = true;
        return done(__ddDMPayload(src, { baseline: 0, incoming: 0, outgoing: 0, reorder: 0, badge: 0, rebuild: 1, activity: 0, visible: 0 }));
      }
      s.rebuilding = false;
      let incoming = 0, outgoing = 0, activity = 0, badge = 0;
      const changes = [];
      for (const item of items) {
        const token = __ddDMToken(item);
        const unpacked = __ddDMUnpack(s.rows.get(item.id));
        const previous = unpacked.token;
        if (previous == null) activity += 1;
        else if (previous !== token) {
          const parts = previous.split('\t');
          if (item.messageID !== parts[0]) {
            if (item.dir === 'in') incoming += 1;
            else if (item.dir === 'out') outgoing += 1;
            else activity += 1;
            changes.push({
              slot: __ddDMSlot(s, item.id), rel: __ddDMRelation(parts[0], item),
              old: unpacked.source, new: item.source, dir: __ddDMDirLabel(item.dir), item
            });
          } else if (item.badge !== parts[1]) badge += 1;
          else s.suppressed += 1;
        }
      }
      const ids = items.map(item => item.id);
      const orderChanged = ids.join('\n') !== s.order.join('\n');
      const reorder = (incoming + outgoing + activity + badge) === 0 && orderChanged ? 1 : 0;
      if ((incoming + outgoing + activity + badge + reorder) === 0) { s.suppressed += 1; return done(null); }
      const seq = __ddDMNextSeq(s);
      if (!__ddDMSeqOk(seq)) { s.seq = 0; s.armed = false; return done(null); }
      s.rows = new Map(items.map(item => [item.id, __ddDMPack(item)]));
      s.order = ids;
      const diagChanges = changes.map(({ slot, rel, old, new: source, dir }) => ({ slot, rel, old, new: source, dir }));
      if (diagChanges.length) __ddDMStageDiag(s, items.length, diagChanges);
      if (globalThis.__ddDMShape === 1) __ddDMStageShape(s, changes);
      const inbound = changes.filter(change => change.dir === 'incoming');
      let extra = null;
      if (changes.length === 1 && inbound.length === 1) {
        if (inbound[0].rel === 'alias-overlap') extra = { alias: 1 };
        else if (inbound[0].rel === 'unlinked-change') {
          const face = __ddDMDisplay(inbound[0].item);
          if (face) extra = { face };
          if (globalThis.__ddDMDirect === 1 && __ddDMStageRoute(s, inbound[0])) {
            extra = extra || {};
            extra.direct = 1;
          }
        }
      }
      const payload = __ddDMPayload(src, { baseline: 0, incoming, outgoing, reorder, badge, rebuild: 0, activity, visible: items.length }, extra);
      if (!payload) globalThis.__ddDMPendingRoute = null;
      return done(payload);
    }
    function __ddDMStats() {
      const s = __ddDMState();
      const list = document.querySelector('[class*="ConversationListwrapper"]');
      const watch = list && globalThis.__ddDMWatchRoot === list ? 1 : 0;
      return JSON.stringify({
        obs: Math.min(s.obs | 0, 1000000), suppressed: Math.min(s.suppressed | 0, 1000000),
        ready: document.readyState === 'complete' ? 1 : 0, hidden: document.hidden ? 1 : 0,
        rows: (s.order || []).length, armed: s.armed ? 1 : 0,
        seqOk: __ddDMSeqOk(s.seq) || s.seq === 0 ? 1 : 0, watch
      });
    }
    globalThis.__ddDMCollect = __ddDMCollect;
    globalThis.__ddDMStats = __ddDMStats;
    globalThis.__ddDMState = __ddDMState;
    globalThis.__ddDMPrepareEpoch = __ddDMPrepareEpoch;
    """#

    static var install: String {
        let arm = (DYDMProbe.shapeEnabled ? "globalThis.__ddDMShape = 1;" : "")
            + (DYDMProbe.directEnabled ? "globalThis.__ddDMDirect = 1;" : "")
        return """
        (() => {
          if (globalThis.__ddDMInstalled) return;
          globalThis.__ddDMInstalled = 1;
          \(arm)
          \(collectJS)
          const watch = () => {
            const root = document.querySelector('[class*="ConversationListwrapper"]') || document.documentElement;
            if (!root || globalThis.__ddDMWatchRoot === root) return;
            globalThis.__ddDMWatchRoot = root;
            if (globalThis.__ddDMObserver) globalThis.__ddDMObserver.disconnect();
            let timer = 0;
            globalThis.__ddDMObserver = new MutationObserver(() => {
              const state = __ddDMState();
              state.obs = Math.min((state.obs || 0) + 1, 1000000);
              state.mutated = Date.now();
              clearTimeout(timer);
              timer = setTimeout(() => {
                const payload = globalThis.__ddDMCollect && globalThis.__ddDMCollect('obs');
                const diag = globalThis.__ddDMPendingDiag || null;
                globalThis.__ddDMPendingDiag = null;
                if (payload) { try { window.webkit.messageHandlers.ddMsg.postMessage(payload); } catch (e) {} }
                if (diag) { try { window.webkit.messageHandlers.ddMsg.postMessage(diag); } catch (e) {} }
                if (globalThis.__ddDMShape === 1) {
                  const shape = globalThis.__ddDMPendingShape || null;
                  globalThis.__ddDMPendingShape = null;
                  if (shape) { try { window.webkit.messageHandlers.ddMsg.postMessage(shape); } catch (e) {} }
                }
                if (globalThis.__ddDMDirect === 1) {
                  const route = globalThis.__ddDMPendingRoute || null;
                  globalThis.__ddDMPendingRoute = null;
                  if (route) { try { window.webkit.messageHandlers.ddMsg.postMessage(route); } catch (e) {} }
                }
              }, 300);
            });
            globalThis.__ddDMObserver.observe(root, { childList: true, subtree: true, characterData: true });
          };
          globalThis.__ddDMWatch = watch;
          watch();
        })();
        """
    }
}

enum DYDMProbeBridge {
    static func consume(_ body: String, message: WKScriptMessage) -> Bool {
        if DYDMProbeGate.isRouteBody(body), !DYDMProbe.directEnabled { return true }
        if DYDMProbeGate.isShapeBody(body), !DYDMProbe.shapeEnabled { return true }
        guard DYDMProbeGate.isRouteBody(body) || DYDMProbeGate.isShapeBody(body) || DYDMProbeGate.isProbeBody(body) || DYDMProbeGate.isDiagBody(body) else { return false }
        let origin = message.frameInfo.securityOrigin
        let scheme = origin.`protocol`
        let host = origin.host
        let port = origin.port
        Task { @MainActor in
            DYChatWebSession.shared.receive(body: body, scheme: scheme, host: host, port: port, requireOrigin: true, rttMs: 0)
        }
        return true
    }
}

@MainActor
final class DYChatWebSession {
    static let shared = DYChatWebSession()
    private weak var parkView: UIView?
    private weak var messagesBox: UIView?
    private var messagesVisible = false
    private var loop: Task<Void, Never>?
    private var started = false
    private var settled = false
    private var creating = false
    private var epoch = 0
    private var lastSeq = 0
    private var ticks = 0
    private var hits: [Date] = []
    private var dropCounts: [String: Int] = [:]
    private var duplicateCount = 0
    private var cpuMark = rusage()
    private var cpuAt = Date()
    private var lastHolder = ""
    private var lastWindow = -1
    private var pendingRoute: (seq: Int, id: String)?
    private var expectingRouteSeq: Int?
    private let chatURL = URL(string: "https://www.douyin.com/chat")!

    func attachPark(_ view: UIView) {
        parkView = view
        startIfNeeded()
        place()
    }

    func detachPark(_ view: UIView) {
        guard parkView === view else { return }
        parkView = nil
        place()
    }

    /// 消息页最后一次的真实尺寸：挂回去时按这个尺寸放，避免从 1200x800 缩到手机宽度整页重排（进信息页那一下卡顿）
    private var lastMessagesSize = CGSize.zero

    func attachMessages(_ view: UIView, model: DouyinWebModel) {
        if view.bounds.size.width > 1, view.bounds.size.height > 1 { lastMessagesSize = view.bounds.size }
        messagesBox = view
        ensureWeb(model)
        place()
    }

    func detachMessages(_ view: UIView) {
        guard messagesBox === view else { return }
        DYMessageCache.shared.retainChat()
        messagesBox = nil
        place()
    }

    var navigationEpoch: Int { epoch }
    var messagesAreVisible: Bool { messagesVisible }

    func noteMessagesSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != lastMessagesSize else { return }
        lastMessagesSize = size
    }

    func setMessagesVisible(_ visible: Bool) {
        messagesVisible = visible
        if !visible { DYMessageCache.shared.retainChat() }
        if visible { DYDMBannerCenter.shared.dismiss() }
        place()
    }

    func noteProvisionalNavigation() {
        epoch &+= 1
        lastSeq = 0
        pendingRoute = nil
        expectingRouteSeq = nil
        DYDMBannerCenter.shared.cancelDirect()
        DYDMBannerCenter.shared.dismiss()
        let window = DYMessageCache.shared.chatModel.web?.window == nil ? 0 : 1
        DYLiveModel.log("DDDM nav start window=\(window)")
    }

    func noteDidFinish() {
        let gen = DYMessageCache.shared.scopeGeneration
        let currentEpoch = epoch
        guard gen > 0, currentEpoch > 0, let web = DYMessageCache.shared.chatModel.web else { return }
        Task { @MainActor in
            _ = try? await web.callAsyncJavaScript(
                "window.__ddDMGen = gen; window.__ddDMEpoch = epoch; return window.__ddDMPrepareEpoch ? window.__ddDMPrepareEpoch() : 1;",
                arguments: ["gen": gen, "epoch": currentEpoch], contentWorld: .page)
            let window = web.window == nil ? 0 : 1
            DYLiveModel.log("DDDM nav finish window=\(window)")
        }
    }

    func noteAccountReset() {
        epoch &+= 1
        lastSeq = 0
        duplicateCount = 0
        dropCounts = [:]
        pendingRoute = nil
        expectingRouteSeq = nil
        DYDMBannerCenter.shared.dismiss()
        DYDMBannerCenter.shared.cancelDirect()
        DYMessageCache.shared.directRouteID = nil
        DYLiveModel.log("DDDM scope reset")
    }

    func receive(body: String, scheme: String?, host: String?, port: Int, requireOrigin: Bool, rttMs: Int) {
        let verdict = DYDMProbeGate.verdict(DYDMProbeGate.Input(
            body: body, scheme: scheme, host: host, port: port,
            generation: DYMessageCache.shared.scopeGeneration, epoch: epoch, lastSeq: lastSeq,
            recentCount: recentCount(), requireOrigin: requireOrigin,
            acceptShape: DYDMProbe.shapeEnabled, acceptRoute: DYDMProbe.directEnabled))
        if case .event = verdict { markHit() }
        finish(verdict, rttMs: rttMs)
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        getrusage(RUSAGE_SELF, &cpuMark)
        cpuAt = Date()
        DYLiveModel.log("DDDM start gate=\(DYDMProbe.enabled ? "setting" : "prewarm")")
        loop = Task { @MainActor in
            while !Task.isCancelled {
                await DYChatWebSession.shared.tick()
                try? await Task.sleep(for: .seconds(DYDMProbe.enabled ? 2 : 4))
            }
        }
    }

    func setMonitoring(_ on: Bool) {
        guard on, DYDMProbe.enabled else {
            stopMonitoring()
            return
        }
        startIfNeeded()
        Task { await armExistingWeb() }
    }

    private func stopMonitoring() {
        loop?.cancel()
        loop = nil
        started = false
        pendingRoute = nil
        expectingRouteSeq = nil
        DYDMBannerCenter.shared.cancelDirect()
        DYDMBannerCenter.shared.dismiss()
        guard let web = DYMessageCache.shared.chatModel.web else { return }
        Task { @MainActor in
            _ = try? await web.evaluateJavaScript("""
            if (window.__ddDMObserver) { window.__ddDMObserver.disconnect(); window.__ddDMObserver = null; }
            window.__ddDMWatchRoot = null; window.__ddDMDirect = 0; window.__ddDMShape = 0; true
            """)
        }
    }

    private func armExistingWeb() async {
        guard DYDMProbe.enabled, let web = DYMessageCache.shared.chatModel.web else { return }
        _ = try? await web.evaluateJavaScript(DYDMProbeScript.install + " window.__ddDMDirect = 1; if (window.__ddDMWatch) window.__ddDMWatch();")
    }

    private func tick() async {
        ticks += 1
        let cache = DYMessageCache.shared
        if !settled || ticks % 15 == 0 {
            await cache.prepare()
            if cache.scopeGeneration > 0 { settled = true }
        }
        // 老板要求「进信息页不用重新加载」：只要已登录就把聊天网页常驻挂着，
        // 跟「私信通知」开关无关；开关只管横幅和轮询。
        if cache.chatModel.web == nil, cache.hasSession || DYDMProbe.enabled { ensureWeb(cache.chatModel) }
        place()
        await DYChatPrewarm.shared.tick(web: cache.chatModel.web, messagesVisible: messagesVisible)
        guard DYDMProbe.enabled else { return }
        await pull()
        if ticks % 15 == 0 { logSample() }
    }

    private func ensureWeb(_ model: DouyinWebModel) {
        guard model.web == nil, !creating else { return }
        creating = true
        defer { creating = false }
        _ = DouyinWebContainer.instantiate(model: model, zoom: 1, start: chatURL, includeProbe: true)
        DYMessageCache.shared.retainChat()
        place()
    }

    private func place() {
        let cache = DYMessageCache.shared
        guard let web = cache.chatModel.web else {
            logHolder("none", window: 0)
            return
        }
        cache.retainChat()
        let target: UIView?
        let holder: String
        if messagesVisible, let box = messagesBox {
            target = box
            holder = "messages"
        } else if let park = parkView {
            target = park
            holder = "park"
        } else {
            target = nil
            holder = "detached"
        }
        guard let target else {
            logHolder(holder, window: web.window == nil ? 0 : 1)
            return
        }
        if web.superview !== target { target.addSubview(web) }
        if holder == "messages" {
            web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            web.frame = target.bounds
            web.isUserInteractionEnabled = true
        } else {
            web.autoresizingMask = []
            let size = lastMessagesSize.width > 1 ? lastMessagesSize : CGSize(width: 1200, height: 800)
            web.frame = CGRect(origin: .zero, size: size)
            web.isUserInteractionEnabled = false
        }
        logHolder(holder, window: web.window == nil ? 0 : 1)
    }

    private var pullScript: String {
        var script = """
        if (window.__ddDMWatch) window.__ddDMWatch();
        const event = window.__ddDMCollect ? window.__ddDMCollect('poll') : null;
        const diag = window.__ddDMPendingDiag || null;
        window.__ddDMPendingDiag = null;
        const box = {event: event, diag: diag};

        """
        if DYDMProbe.shapeEnabled {
            script += """
            box.shape = window.__ddDMPendingShape || null;
            window.__ddDMPendingShape = null;

            """
        }
        if DYDMProbe.directEnabled {
            script += """
            box.route = window.__ddDMPendingRoute || null;
            window.__ddDMPendingRoute = null;

            """
        }
        return script + "return JSON.stringify(box);"
    }

    private func pull() async {
        guard let web = DYMessageCache.shared.chatModel.web else { return }
        guard let url = web.url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), DYDMProbeGate.trustedHosts.contains(host) else {
            if ticks % 5 == 0 { DYLiveModel.log("DDDM pull skip host window=\(web.window == nil ? 0 : 1)") }
            return
        }
        let started = Date()
        let value: Any?
        do {
            value = try await web.callAsyncJavaScript(pullScript, arguments: [:], contentWorld: .page)
        } catch {
            DYLiveModel.log("DDDM pull fail")
            return
        }
        let rtt = Int(Date().timeIntervalSince(started) * 1000)
        if let text = value as? String,
           let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["event"] != nil || obj["diag"] != nil {
            if let event = obj["event"] as? String {
                receive(body: event, scheme: url.scheme, host: host, port: url.port ?? 443, requireOrigin: false, rttMs: rtt)
            }
            if let diag = obj["diag"] as? String {
                receive(body: diag, scheme: url.scheme, host: host, port: url.port ?? 443, requireOrigin: false, rttMs: rtt)
            }
            if let shape = obj["shape"] as? String {
                receive(body: shape, scheme: url.scheme, host: host, port: url.port ?? 443, requireOrigin: false, rttMs: rtt)
            }
            if let route = obj["route"] as? String {
                receive(body: route, scheme: url.scheme, host: host, port: url.port ?? 443, requireOrigin: false, rttMs: rtt)
            }
            if obj["event"] is String { return }
        } else if let text = value as? String {
            receive(body: text, scheme: url.scheme, host: host, port: url.port ?? 443, requireOrigin: false, rttMs: rtt)
            return
        }
        if ticks % 5 == 0 {
            let stats = await stats(web)
            let watch = stats.watch == 1 ? "list" : "doc"
            DYLiveModel.log("DDDM pull quiet window=\(web.window == nil ? 0 : 1) rttMs=\(rtt) ready=\(stats.ready) hidden=\(stats.hidden) obs=\(stats.obs) suppressed=\(stats.suppressed) rows=\(stats.rows) armed=\(stats.armed) seqOk=\(stats.seqOk) watch=\(watch)")
        }
    }

    private func stats(_ web: WKWebView) async -> (obs: Int, suppressed: Int, ready: Int, hidden: Int, rows: Int, armed: Int, seqOk: Int, watch: Int) {
        let value = try? await web.callAsyncJavaScript("return window.__ddDMStats ? window.__ddDMStats() : null;", arguments: [:], contentWorld: .page)
        guard let text = value as? String, text.utf8.count <= 240,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (0, 0, 0, 0, 0, 0, 0, 0)
        }
        func n(_ key: String) -> Int { (obj[key] as? NSNumber)?.intValue ?? 0 }
        return (n("obs"), n("suppressed"), n("ready"), n("hidden"), n("rows"), n("armed"), n("seqOk"), n("watch"))
    }

    private func finish(_ verdict: DYDMProbeGate.Verdict, rttMs: Int) {
        switch verdict {
        case .forward:
            break
        case .drop(let reason):
            if reason == "duplicate" { duplicateCount += 1 }
            let count = (dropCounts[reason] ?? 0) + 1
            dropCounts[reason] = count
            if count == 1 || count % 10 == 0 {
                DYLiveModel.log("DDDM drop reason=\(reason) n=\(count) dup=\(duplicateCount)")
            }
            if reason == "schema-seq" { releaseRejectedBaseline() }
        case .diagnostic(let diag):
            for change in diag.changes {
                DYLiveModel.log("DDDM diag eventSeq=\(diag.eventSeq) rows=\(diag.rows) n=\(diag.count) slot=\(change.slot) rel=\(change.relation) old=\(change.oldSource) new=\(change.newSource) dir=\(change.direction) truncated=\(diag.truncated)")
            }
        case .shape(let shape):
            guard DYDMProbe.shapeEnabled else { return }
            DYLiveModel.log("DDDM shape eventSeq=\(shape.eventSeq) message=\(shape.message) identifier=\(shape.identifier) dir=\(shape.direction) alias=\(shape.alias) multi=\(shape.multiple) object=\(shape.sameObject) held=\(shape.withheld) content=\(shape.content) parsed=\(shape.parsed) text=\(shape.text) inner=\(shape.inner) parsedText=\(shape.parsedText) awe=\(shape.awe) messageType=\(shape.messageType) status=\(shape.status) recall=\(shape.recall)")
        case .route(let route):
            guard DYDMProbe.directEnabled else { return }
            if expectingRouteSeq == route.eventSeq {
                expectingRouteSeq = nil
                DYDMBannerCenter.shared.replaceRoute(route.id)
            } else if route.eventSeq > lastSeq {
                pendingRoute = (route.eventSeq, route.id)
            }
            DYLiveModel.log("DDDM route accept=1")
        case .event(let event):
            lastSeq = event.seq
            let window = DYMessageCache.shared.chatModel.web?.window == nil ? 0 : 1
            if event.baseline == 1 {
                DYLiveModel.log("DDDM baseline src=\(event.src) rows=\(event.visible) window=\(window) ready=\(event.ready) hidden=\(event.hidden) rttMs=\(rttMs) genOk=1")
                return
            }
            let kind = event.incoming > 0 ? "incoming" : (event.outgoing > 0 ? "outgoing" : "activity")
            DYLiveModel.log("DDDM event class=\(kind) src=\(event.src) in=\(event.incoming) out=\(event.outgoing) reorder=\(event.reorder) badge=\(event.badge) rebuild=\(event.rebuild) activity=\(event.activity) dup=\(duplicateCount) lagMs=\(event.lagMs) rttMs=\(rttMs) window=\(window) ready=\(event.ready) hidden=\(event.hidden) obs=\(event.observer) genOk=1")
            if event.incoming > 0 {
                if event.aliasOnly {
                    // The conversation did not change. Keep the route already on the banner.
                } else if event.directReady, let pending = pendingRoute, pending.seq == event.seq {
                    pendingRoute = nil
                    expectingRouteSeq = nil
                    DYDMBannerCenter.shared.replaceRoute(pending.id)
                } else {
                    pendingRoute = nil
                    expectingRouteSeq = event.directReady ? event.seq : nil
                    DYDMBannerCenter.shared.replaceRoute(nil)
                }
                DYDMBannerCenter.shared.noteIncoming(generation: DYMessageCache.shared.scopeGeneration, epoch: epoch,
                    aliasOnly: event.aliasOnly, kind: event.faceKind, name: event.faceName, avatar: event.faceAvatar)
            }
        }
    }

    /// A rejected sequence is not a baseline. Allow the next poll to initialize again
    /// without clearing a finite sequence or moving the WebView.
    private func releaseRejectedBaseline() {
        guard let web = DYMessageCache.shared.chatModel.web else { return }
        Task { @MainActor in
            _ = try? await web.callAsyncJavaScript(
                "return window.__ddDMPrepareEpoch ? window.__ddDMPrepareEpoch() : 0;",
                arguments: [:], contentWorld: .page)
        }
    }

    private func recentCount() -> Int {
        let now = Date()
        hits.removeAll { now.timeIntervalSince($0) >= 1 }
        return hits.count
    }

    private func markHit() { hits.append(Date()) }

    private func logHolder(_ holder: String, window: Int) {
        guard holder != lastHolder || window != lastWindow else { return }
        lastHolder = holder
        lastWindow = window
        DYLiveModel.log("DDDM place holder=\(holder) window=\(window)")
    }

    private func logSample() {
        var now = rusage()
        getrusage(RUSAGE_SELF, &now)
        let elapsed = Date().timeIntervalSince(cpuAt)
        let used = seconds(now.ru_utime) - seconds(cpuMark.ru_utime) + seconds(now.ru_stime) - seconds(cpuMark.ru_stime)
        let cpu = elapsed > 0 ? min(999, max(0, Int((used / elapsed) * 100))) : 0
        cpuMark = now
        cpuAt = Date()
        DYLiveModel.log("DDDM sample memMB=\(memoryMB()) cpuPct=\(cpu) dup=\(duplicateCount)")
    }

    private func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    private func memoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.resident_size / (1024 * 1024))
    }
}

struct DYChatWebParkHost: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.alpha = 0.01
        view.backgroundColor = .clear
        context.coordinator.bind(view)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.bind(uiView) }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.unbind(uiView) }
    @MainActor
    final class Coordinator {
        func bind(_ view: UIView) { DYChatWebSession.shared.attachPark(view) }
        func unbind(_ view: UIView) { DYChatWebSession.shared.detachPark(view) }
    }
}

struct DYChatProbeSurface: UIViewRepresentable {
    @ObservedObject var model: DouyinWebModel
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = .clear
        box.clipsToBounds = true
        context.coordinator.bind(box, model: model)
        return box
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.bind(uiView, model: model)
    }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.unbind(uiView) }
    @MainActor
    final class Coordinator {
        func bind(_ view: UIView, model: DouyinWebModel) { DYChatWebSession.shared.attachMessages(view, model: model) }
        func unbind(_ view: UIView) { DYChatWebSession.shared.detachMessages(view) }
    }
}
