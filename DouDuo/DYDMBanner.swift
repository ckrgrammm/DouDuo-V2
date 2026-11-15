import Foundation
import SwiftUI
import UIKit
import WebKit

/// User setting for the foreground banner. Off until the person opts in.
enum DYDMBannerGate {
    static var enabled: Bool { DYDMProbe.enabled }
}

enum DYDMSenderGate {
    static var enabled: Bool { DYDMNotificationSettings.showsDetail && !DYDMProbe.blocksFixture }
}

// BEGIN DYDMBannerPolicy
enum DYDMNotificationSettings {
    static let notifyKey = "doudou.dm.notify.v1"
    static let detailKey = "doudou.dm.detail.v1"

    static func notifications(in store: UserDefaults) -> Bool { store.bool(forKey: notifyKey) }

    /// Names and avatars require the notification switch as well.
    static func showsDetail(in store: UserDefaults) -> Bool {
        notifications(in: store) && store.bool(forKey: detailKey)
    }

    static var notificationsOn: Bool { notifications(in: .standard) }
    static var showsDetail: Bool { showsDetail(in: .standard) }
}

enum DYDMBannerPolicy {
    struct Input: Equatable {
        var probeEnabled: Bool
        var bannerEnabled: Bool
        var releaseBuild: Bool
        var incoming: Int
        var baseline: Bool
        var diagnosticOnly: Bool
        var messagesVisible: Bool
        var appActive: Bool
        var hasSession: Bool
        var eventGeneration: Int
        var currentGeneration: Int
        var eventEpoch: Int
        var currentEpoch: Int
        var bannerVisible: Bool
        var senderEnabled: Bool
        var aliasOnly: Bool
    }

    enum Decision: Equatable {
        case ignore
        case present
        case coalesce
        case suppress(String)
    }

    static func decide(_ input: Input) -> Decision {
        if !input.probeEnabled || !input.bannerEnabled { return .ignore }
        if input.diagnosticOnly || input.baseline || input.incoming <= 0 { return .ignore }
        if !input.hasSession { return .suppress("session") }
        if !input.appActive { return .suppress("inactive") }
        if input.messagesVisible { return .suppress("messages") }
        if input.eventGeneration != input.currentGeneration || input.eventEpoch != input.currentEpoch {
            return .suppress("stale")
        }
        if input.senderEnabled && input.aliasOnly { return .suppress("alias") }
        if input.bannerVisible { return .coalesce }
        return .present
    }

    static let shakeDistance: CGFloat = 4.5
    static let shakeScale: CGFloat = 1.025

    static func animates(reduceMotion: Bool) -> Bool { !reduceMotion }

    /// The first presentation keeps pulse at zero. Later refreshes increment it.
    static func shakeActive(pulse: Int, reduceMotion: Bool) -> Bool { pulse > 0 && !reduceMotion }

    static let imageHosts = ["douyin.com", "douyinpic.com", "douyinvod.com", "iesdouyin.com", "amemv.com", "snssdk.com", "bytedance.com", "zijieapi.com"]

    static func displayName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count), !name.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else { return nil }
        return name
    }

    static func copy(kind: Int, name raw: String) -> (title: String, message: String)? {
        guard let name = displayName(raw) else { return nil }
        if kind == 1 { return (name, "你有新的私信活动") }
        if kind == 2 { return (name, "群聊有新的私信活动") }
        return nil
    }

    static func avatarURL(_ raw: String) -> URL? {
        guard !raw.isEmpty, raw.count <= 180, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              imageHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }
}

struct DYDMBannerPresentation: Equatable {
    static let genericTitle = "有新消息"
    static let singleMessage = "你有新的私信活动"
    static let manyMessage = "有多条新的私信活动"

    struct Update: Equatable {
        var reliable: Bool
        var title: String
        var message: String
        var senderEnabled: Bool
    }

    var token = 0
    var visible = false
    var events = 0
    var pulse = 0
    var title = genericTitle
    var message = singleMessage
    var enriched = false

    mutating func receive(_ decision: DYDMBannerPolicy.Decision, _ update: Update) -> Int? {
        switch decision {
        case .ignore, .suppress:
            return nil
        case .present, .coalesce:
            token += 1
            visible = true
            if decision == .present { events = 1 } else { events += 1 }
            if decision == .coalesce { pulse += 1 }
            if update.senderEnabled && update.reliable {
                title = update.title
                enriched = true
            } else {
                title = Self.genericTitle
                enriched = false
            }
            if events > 1 {
                message = Self.manyMessage
            } else if update.senderEnabled && update.reliable {
                message = update.message
            } else {
                message = Self.singleMessage
            }
            return token
        }
    }

    mutating func dismiss(scheduledToken: Int) -> Bool {
        guard visible, scheduledToken == token else { return false }
        clear()
        return true
    }

    mutating func invalidate() {
        token += 1
        clear()
    }

    private mutating func clear() {
        visible = false
        events = 0
        title = Self.genericTitle
        message = Self.singleMessage
        enriched = false
    }

    mutating func concealIdentity() {
        title = Self.genericTitle
        enriched = false
    }
}

struct DYDMDirectIntent: Equatable {
    var token: Int
    var generation: Int
    var epoch: Int
    var route: String

    var listID: String { "conversation:" + route }

    func allows(generation: Int, epoch: Int, webUnchanged: Bool) -> Bool {
        webUnchanged && self.generation == generation && self.epoch == epoch && !route.isEmpty
    }
}

struct DYDMRouteState: Equatable {
    var route: String?
    private(set) var intentToken = 0
    private(set) var active: DYDMDirectIntent?

    mutating func apply(keep: Bool, routeID: String?) {
        if keep { return }
        route = routeID.flatMap(Self.normalized)
    }

    mutating func claim(generation: Int, epoch: Int, enabled: Bool) -> DYDMDirectIntent? {
        guard enabled, let route, !route.isEmpty else { return nil }
        intentToken += 1
        let intent = DYDMDirectIntent(token: intentToken, generation: generation, epoch: epoch, route: route)
        active = intent
        return intent
    }

    func allows(_ intent: DYDMDirectIntent, generation: Int, epoch: Int, webUnchanged: Bool) -> Bool {
        active?.token == intent.token && intent.allows(generation: generation, epoch: epoch, webUnchanged: webUnchanged)
    }

    mutating func cancel() {
        intentToken += 1
        active = nil
        route = nil
    }

    static func normalized(_ raw: String) -> String? {
        guard (1...80).contains(raw.count),
              raw.unicodeScalars.allSatisfy({ $0.value >= 32 && !$0.properties.isWhitespace }) else { return nil }
        return raw
    }
}

enum DYDMDirectCommit {
    static func accept(opened: Bool, allowed: Bool) -> Bool { opened && allowed }
    static func undo(opened: Bool, allowed: Bool) -> Bool { opened && !allowed }
}
// END DYDMBannerPolicy

@MainActor
final class DYDMBannerCenter: ObservableObject {
    static let shared = DYDMBannerCenter()
    struct Display: Equatable {
        var title: String
        var message: String
        var avatarURL: URL?
    }

    @Published private(set) var visible = false
    @Published private(set) var pulse = 0
    @Published private(set) var display: Display?
    private var presentation = DYDMBannerPresentation()
    private var dismissTask: Task<Void, Never>?
    private var routes = DYDMRouteState()

    func noteIncoming(generation: Int, epoch: Int, aliasOnly: Bool, kind: Int, name: String, avatar: String) {
        let sender = DYDMSenderGate.enabled
        let decision = DYDMBannerPolicy.decide(DYDMBannerPolicy.Input(
            probeEnabled: DYDMProbe.enabled,
            bannerEnabled: DYDMBannerGate.enabled,
            releaseBuild: {
                #if DEBUG
                false
                #else
                true
                #endif
            }(),
            incoming: 1,
            baseline: false,
            diagnosticOnly: false,
            messagesVisible: DYChatWebSession.shared.messagesAreVisible,
            appActive: UIApplication.shared.applicationState == .active,
            hasSession: DYMessageCache.shared.hasSession,
            eventGeneration: generation,
            currentGeneration: DYMessageCache.shared.scopeGeneration,
            eventEpoch: epoch,
            currentEpoch: DYChatWebSession.shared.navigationEpoch,
            bannerVisible: visible,
            senderEnabled: sender,
            aliasOnly: sender && aliasOnly))
        let copy = sender && !aliasOnly ? DYDMBannerPolicy.copy(kind: kind, name: name) : nil
        guard let token = presentation.receive(decision, DYDMBannerPresentation.Update(
            reliable: copy != nil, title: copy?.title ?? DYDMBannerPresentation.genericTitle,
            message: copy?.message ?? DYDMBannerPresentation.singleMessage, senderEnabled: sender)) else { return }
        let shownAvatar = sender && presentation.enriched ? DYDMBannerPolicy.avatarURL(avatar) : nil
        display = Display(title: presentation.title, message: presentation.message, avatarURL: shownAvatar)
        visible = true
        pulse = presentation.pulse
        DYLiveModel.log("DDDM banner decision=\(decision == .present ? "present" : "refresh") token=\(token) events=\(presentation.events)")
        scheduleDismiss(token)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        presentation.invalidate()
        visible = false
        display = nil
        pulse = presentation.pulse
        routes.apply(keep: false, routeID: nil)
    }

    func concealIdentity() {
        presentation.concealIdentity()
        guard var shown = display else { return }
        shown.title = presentation.title
        shown.avatarURL = nil
        display = shown
    }

    func replaceRoute(_ id: String?) {
        guard presentation.visible else {
            routes.apply(keep: false, routeID: nil)
            return
        }
        routes.apply(keep: false, routeID: id)
    }

    func cancelDirect() {
        routes.cancel()
        DYDMDirectOpen.cancel()
    }

    func openTapped(openMessages: @escaping () -> Void) {
        let generation = DYMessageCache.shared.scopeGeneration
        let epoch = DYChatWebSession.shared.navigationEpoch
        let web = DYMessageCache.shared.chatModel.web
        let intent = routes.claim(generation: generation, epoch: epoch, enabled: DYDMProbe.directEnabled && web != nil)
        let title = display?.title ?? ""
        dismiss()
        if let intent, let web {
            DYDMDirectOpen.start(intent: intent, web: web, title: title, openMessages: openMessages)
        } else {
            openMessages()
        }
    }

    func routeAllows(_ intent: DYDMDirectIntent, web marker: ObjectIdentifier) -> Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        guard let web = DYMessageCache.shared.chatModel.web, ObjectIdentifier(web) == marker else { return false }
        return routes.allows(intent, generation: DYMessageCache.shared.scopeGeneration, epoch: DYChatWebSession.shared.navigationEpoch, webUnchanged: true)
    }

    private func scheduleDismiss(_ token: Int) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            guard presentation.dismiss(scheduledToken: token) else { return }
            visible = false
            display = nil
        }
    }
}

struct DYDMBannerModifier: ViewModifier {
    var messagesVisible: Bool
    var openMessages: () -> Void
    @ObservedObject private var center = DYDMBannerCenter.shared
    @ObservedObject private var cache = DYMessageCache.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(DYDMNotificationSettings.notifyKey) private var notifications = false
    @AppStorage(DYDMNotificationSettings.detailKey) private var showDetail = false

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if DYDMBannerGate.enabled, center.visible, !messagesVisible {
                DYDMBannerCard(
                    title: center.display?.title ?? DYDMBannerPresentation.genericTitle,
                    message: center.display?.message ?? "你有新的私信活动",
                    avatar: center.display?.avatarURL.flatMap { ImageCache.shared.memoryCached($0) },
                    reduceMotion: reduceMotion
                ) {
                    center.openTapped(openMessages: openMessages)
                }
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .modifier(DYDMBannerRefreshMotion(pulse: center.pulse, reduceMotion: reduceMotion))
                .transition(DYDMBannerPolicy.animates(reduceMotion: reduceMotion) ? .move(edge: .top).combined(with: .opacity) : .opacity)
            }
        }
        .animation(DYDMBannerPolicy.animates(reduceMotion: reduceMotion) ? .easeOut(duration: 0.25) : nil, value: center.visible)
        .onChange(of: messagesVisible) { _, open in
            if open { center.dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                center.cancelDirect()
                center.dismiss()
            }
        }
        .onChange(of: cache.scopeGeneration) { _, _ in
            center.cancelDirect()
            center.dismiss()
        }
        .onChange(of: notifications) { _, on in
            if !on {
                center.cancelDirect()
                center.dismiss()
            }
            DYChatWebSession.shared.setMonitoring(on)
        }
        .onChange(of: showDetail) { _, on in
            if !on || !notifications { center.concealIdentity() }
        }
        .onAppear { DYChatWebSession.shared.setMonitoring(notifications) }
    }
}

private struct DYDMBannerRefreshMotion: ViewModifier {
    var pulse: Int
    var reduceMotion: Bool
    @State private var generation = 0
    @State private var offset: CGFloat = 0
    @State private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : scale, anchor: .center)
            .offset(x: reduceMotion ? 0 : offset)
            .onChange(of: pulse) { _, new in play(new) }
            .onChange(of: reduceMotion) { _, _ in rest() }
    }

    private func rest() {
        generation += 1
        offset = 0
        scale = 1
    }

    private func play(_ pulse: Int) {
        rest()
        guard DYDMBannerPolicy.shakeActive(pulse: pulse, reduceMotion: reduceMotion) else { return }
        let current = generation
        Task { @MainActor in
            let steps: [(CGFloat, CGFloat, Duration)] = [
                (-DYDMBannerPolicy.shakeDistance, DYDMBannerPolicy.shakeScale, .milliseconds(70)),
                (DYDMBannerPolicy.shakeDistance, 1.012, .milliseconds(80)),
                (-2.5, 1.004, .milliseconds(80)),
                (0, 1, .milliseconds(90))
            ]
            for step in steps {
                guard current == generation else { return }
                withAnimation(.spring(response: 0.16, dampingFraction: 0.62)) {
                    offset = step.0
                    scale = step.1
                }
                try? await Task.sleep(for: step.2)
            }
            guard current == generation else { return }
            offset = 0
            scale = 1
        }
    }
}

enum DYDMDirectOpen {
    private static var task: Task<Void, Never>?

    static func cancel() {
        task?.cancel()
        task = nil
    }

    static func start(intent: DYDMDirectIntent, web: WKWebView, title: String, openMessages: @escaping () -> Void) {
        task?.cancel()
        let marker = ObjectIdentifier(web)
        let name = title == DYDMBannerPresentation.genericTitle ? "" : title
        task = Task { @MainActor in
            let row = DYConversationRow(
                id: intent.listID, name: name, avatar: nil, preview: "", time: "", badge: "", index: "0",
                stranger: false, kind: nil, sec: nil, streak: nil, isPinned: nil, lastMessageTime: nil, lastMessageID: nil)
            DYMessageCache.shared.selectedChat = row
            DYMessageCache.shared.directRouteID = intent.listID
            openMessages()
            var opened = false
            @MainActor func allowed() -> Bool {
                !Task.isCancelled && DYDMBannerCenter.shared.routeAllows(intent, web: marker)
            }
            @MainActor func settle(_ result: DYChatOpener.Result, on web: WKWebView) async -> Bool {
                let keep = allowed()
                let didOpen: Bool
                if case .opened = result { didOpen = true } else { didOpen = false }
                if DYDMDirectCommit.undo(opened: didOpen, allowed: keep) {
                    await DYChatOpener.restoreList(web)
                }
                return DYDMDirectCommit.accept(opened: didOpen, allowed: keep)
            }
            for _ in 0..<40 {
                guard allowed() else { break }
                if let current = DYMessageCache.shared.chatModel.web, ObjectIdentifier(current) == marker, !current.isLoading {
                    let result = await DYChatOpener.open(row, web: current)
                    if await settle(result, on: current) {
                        opened = true
                    } else if case .notReady = result, allowed() {
                        try? await Task.sleep(for: .milliseconds(1500))
                        if allowed(), let again = DYMessageCache.shared.chatModel.web, ObjectIdentifier(again) == marker {
                            let retry = await DYChatOpener.open(row, web: again)
                            opened = await settle(retry, on: again)
                        }
                    }
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if !opened {
                if DYMessageCache.shared.selectedChat?.id == intent.listID { DYMessageCache.shared.selectedChat = nil }
                if DYMessageCache.shared.directRouteID == intent.listID { DYMessageCache.shared.directRouteID = nil }
            }
            DYLiveModel.log("DDDM direct result=\(opened ? "opened" : "list")")
        }
    }
}

struct DYDMBannerCard: View {
    var title: String = DYDMBannerPresentation.genericTitle
    var message: String = "你有新的私信活动"
    var avatar: UIImage? = nil
    var reduceMotion: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let avatar {
                    Image(uiImage: avatar)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.body.weight(.semibold))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 340)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(reduceMotion ? 0 : 0.28), radius: reduceMotion ? 0 : 16, y: 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityIdentifier("douyin.dm.banner")
        .accessibilityLabel(title)
        .accessibilityValue(message)
        .accessibilityHint("打开消息")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("DM banner") {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack {
            DYDMBannerCard(reduceMotion: false, action: {})
                .padding(.top, 12)
            Spacer()
        }
    }
    .preferredColorScheme(.dark)
}

struct DYDMMonitorHost: View {
    var body: some View {
        // 不再只在「私信通知」打开时才挂：聊天网页需要常驻窗口，进信息页才能秒开
        // （通知开关只控制横幅与轮询，见 DYDMProbe.enabled）
        if !DYDMProbe.blocksFixture {
            DYChatWebParkHost()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
