// DouDuo 三姿态：外屏 / 半折叠 / 内屏平放。
// iOS 27.1 用 ArrangementView.overlay（书本：视频 leading、评论 trailing；桌面：视频在上、评论在下）。
// 更低版本回退容器宽度 wide>=700，不读方向、不读 UIScreen。
import SwiftUI
import UIKit

/// Shared by the main feed and videos opened from search/profile grids.
struct DYCommentLayout {
    let size: CGSize
    let fold: Bool
    let showComments: Bool
    var bookFold: Bool { fold && size.width > size.height }
    var tableFold: Bool { fold && size.width <= size.height }
    var sideBySide: Bool { !tableFold && (size.width >= DYDuoMetrics.legacyWideMin || bookFold) }
    var showPanel: Bool { fold || (showComments && sideBySide) }
    var panelWidth: CGFloat {
        showPanel && sideBySide ? (bookFold ? size.width * 0.45 : min(380, size.width * 0.42)) : 0
    }
    var panelHeight: CGFloat { tableFold ? size.height * 0.45 : 0 }
    var videoWidth: CGFloat { size.width - panelWidth }
    var videoHeight: CGFloat { size.height - panelHeight }
    /// 外屏（窄屏、未半折叠）：评论不再是浮窗，视频缩到面板上方继续播（见 DYCommentDock）
    var docked: Bool { !sideBySide && !fold }
}

private struct DYCommentsDockedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// 视频被评论面板挤到上方时为 true：视频页隐藏右侧按钮栏/文案，只留画面
    var dyCommentsDocked: Bool {
        get { self[DYCommentsDockedKey.self] }
        set { self[DYCommentsDockedKey.self] = newValue }
    }
}

/// 外屏评论（仿官方）：面板从底部升起占约 2/3 高，视频整体等比缩小、移到面板上方继续播放；
/// 下拉面板顶部时视频跟手放大，松手过 1/4 或甩得快就收起，点上方视频也收起。
/// 视频本身的布局尺寸始终不变（只做缩放变换），所以开关评论不会重排/重建播放器。
struct DYCommentDock<Video: View, Panel: View>: View {
    /// 当前姿态是否走「视频 + 评论」联动（内屏并排/桌面模式时为 false，直接透传）
    let enabled: Bool
    @Binding var isOpen: Bool
    @ViewBuilder var video: () -> Video
    @ViewBuilder var panel: () -> Panel
    @State private var drag: CGFloat = 0
    /// 键盘上沿（全局坐标），没有键盘时为 +∞
    @State private var keyboardTop: CGFloat = .infinity

    /// 窗口顶部安全区。⚠️ 不能在 body 里直接读 UIWindow.safeAreaInsets：
    /// 更新过程中读它会让 UIKit 重入布局宿主窗口，外屏上整个 SwiftUI 就停在首帧（一直「连接抖音…」、点不动）。
    /// 所以只在出现/开关评论时读一次存起来。
    @State private var windowTop: CGFloat = 0

    static var panelFraction: CGFloat { 0.68 }

    private static var windowTopInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        return window?.safeAreaInsets.top ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let open = enabled && isOpen
            let panelH = (h * Self.panelFraction).rounded()
            // 宿主普遍忽略顶部安全区（geo 里读到 0），兜底用窗口的，让缩小后的视频躲开状态栏/灵动岛
            let top = max(geo.safeAreaInsets.top, windowTop)
            // 0 = 全屏视频，1 = 面板完全展开
            let progress = open ? max(0, min(1, (panelH - drag) / panelH)) : 0
            let shown = panelH * progress
            let scale = max(0.05, (h - shown - top * progress) / h)
            let lift = max(0, geo.frame(in: .global).maxY - keyboardTop)
            let frameH = max(0, min(panelH, h - lift - top))
            ZStack(alignment: .topLeading) {
                video()
                    .frame(width: w, height: h)
                    .environment(\.dyCommentsDocked, open)
                    .scaleEffect(scale, anchor: .top)
                    .offset(y: top * progress)
                    .allowsHitTesting(!open)
                if open {
                    // 面板上方的视频区：点一下收起，也能往下拖
                    Color.black.opacity(0.001)
                        .frame(width: w, height: max(0, h - shown))
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .gesture(dragGesture(panelH))
                        .accessibilityLabel("收起评论")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("douyin.comments.dockDismiss")
                    VStack(spacing: 0) {
                        panel()
                            .frame(width: w, height: frameH)
                        // 宿主底部不一定铺到 Home 指示条下面：补一截同色底，免得面板下方露黑边
                        Rectangle().fill(.regularMaterial).frame(width: w, height: 120)
                            .allowsHitTesting(false)
                    }
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
                        .frame(width: w, height: frameH, alignment: .top)
                        .overlay(alignment: .top) {
                            // 拖拽把手：标题栏左侧大部分区域（右侧留给关闭按钮）
                            Capsule().fill(.secondary.opacity(0.5)).frame(width: 36, height: 4)
                                .padding(.top, 5)
                                .frame(maxWidth: .infinity)
                                .allowsHitTesting(false)
                        }
                        .overlay(alignment: .topLeading) {
                            Color.clear
                                .frame(width: max(0, w - 64), height: 52)
                                .contentShape(Rectangle())
                                .gesture(dragGesture(panelH))
                        }
                        .offset(y: h - lift - frameH + drag)
                        .transition(.move(edge: .bottom))
                        .accessibilityIdentifier("douyin.comments.dock")
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .animation(.snappy, value: open)
        }
        .onAppear { DispatchQueue.main.async { windowTop = Self.windowTopInset } }
        .onChange(of: isOpen) { _, o in
            if !o { drag = 0 } else { windowTop = Self.windowTopInset }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            withAnimation(.snappy) { keyboardTop = f.height > 0 ? f.minY : .infinity }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.snappy) { keyboardTop = .infinity }
        }
    }

    private func close() {
        withAnimation(.snappy) { isOpen = false; drag = 0 }
    }

    private func dragGesture(_ panelH: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in drag = max(0, v.translation.height) }
            .onEnded { v in
                let fling = v.predictedEndTranslation.height - v.translation.height
                if drag > panelH * 0.25 || fling > 260 { close() }
                else { withAnimation(.snappy) { drag = 0 } }
            }
    }
}

enum DYDuoMetrics {
    /// iOS 17–27.0 的宽屏回退，和改版前同一条线。
    static let legacyWideMin: CGFloat = 700

    /// 折痕是否处于激活状态（半折叠）。iOS 27.1 以下恒为 false。
    static func foldIsActive(_ proxy: GeometryProxy) -> Bool {
        #if DEBUG
        // 演示/截图用：模拟器没有物理折痕，用环境变量强制进入半折叠布局
        if ProcessInfo.processInfo.environment["DOUDUO_FOLD"] == "1" { return true }
        #endif
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division).contains { $0.isActive }
        }
        return false
    }

    /// 顶栏左移量：合屏时前摄挖孔压在右上，整排往左让出它的宽度，避免「推荐/直播」被啃掉。
    /// 只认靠上且靠右的 occlusion；下方/居中的（如外屏下缘）不动顶栏。
    static func topBarLeftShift(_ proxy: GeometryProxy) -> CGFloat {
        guard #available(iOS 27.1, *) else { return 0 }
        let w = proxy.size.width
        var shift: CGFloat = 0
        for r in proxy.reservedRegions(kind: .occlusion) where r.isActive {
            let f = r.frame
            guard f.height > 1, f.width > 1 else { continue }
            // 顶部 140pt 内、且位于右半边 → 认定为前摄
            if f.minY < 140, f.minX > w * 0.5 {
                shift = max(shift, f.width)
            }
        }
        return min(shift, 56)
    }
}

// MARK: - 折痕 / 摄像头：整组小幅平移，不大挪

private struct DYNudgePref: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// 自定义按钮栏避开 active 的 occlusion（外屏摄像头）和 division（折痕）。
/// 测量放在未平移的布局框上，平移只作用于内容，避免来回抖。
struct DYRailReservedNudge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            DYRailReservedNudgeBox { content }
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct DYRailReservedNudgeBox<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var nudge: CGSize = .zero

    var body: some View {
        content()
            .offset(nudge)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: DYNudgePref.self, value: DYReservedNudge.offset(in: proxy))
                }
            }
            .onPreferenceChange(DYNudgePref.self) { new in
                if hypot(new.width - nudge.width, new.height - nudge.height) > 0.5 { nudge = new }
            }
    }
}

@available(iOS 27.1, *)
enum DYReservedNudge {
    /// 在视图自己的坐标里，把和遮挡区相交的部分挪到最近的一侧。摄像头优先向下，符合外屏「小幅下移」。
    static func offset(in proxy: GeometryProxy) -> CGSize {
        let local = CGRect(origin: .zero, size: proxy.size)
        guard local.width > 1, local.height > 1 else { return .zero }
        var box = local
        var acc = CGSize.zero
        for region in proxy.reservedRegions(kind: .occlusion) where region.isActive && region.frame.intersects(box) {
            let d = clear(box, region.frame, preferDown: true)
            acc.width += d.width
            acc.height += d.height
            box = box.offsetBy(dx: d.width, dy: d.height)
        }
        for region in proxy.reservedRegions(kind: .division) where region.isActive && region.frame.intersects(box) {
            let d = clear(box, region.frame, preferDown: false)
            acc.width += d.width
            acc.height += d.height
            box = box.offsetBy(dx: d.width, dy: d.height)
        }
        return acc
    }

    private static func clear(_ box: CGRect, _ region: CGRect, preferDown: Bool) -> CGSize {
        let left = CGSize(width: region.minX - box.maxX, height: 0)
        let right = CGSize(width: region.maxX - box.minX, height: 0)
        let up = CGSize(width: 0, height: region.minY - box.maxY)
        let down = CGSize(width: 0, height: region.maxY - box.minY)
        let mag: (CGSize) -> CGFloat = { abs($0.width) + abs($0.height) }
        let best = [left, right, up, down].min { mag($0) < mag($1) } ?? .zero
        if preferDown, mag(down) <= mag(best) + 24 { return down }
        return best
    }
}

// MARK: - ArrangementView 主面板

/// zIndex > 0：平放 / 外屏，面板浮在视频上，维持「点了才出」。
/// zIndex == 0：半折叠，系统把 primary 分到 trailing / 底部，面板常驻。
@available(iOS 27.1, *)
struct DYDuoCommentPrimary: View {
    @Environment(\.overlayArrangementZIndex) private var zIndex
    @Environment(\.horizontalSizeClass) private var hSize
    let bridge: DouyinBridge
    let aweme: DYAweme?
    let showComments: Bool
    let onClose: () -> Void
    let onAuthor: () -> Void

    var body: some View {
        if zIndex == 0 {
            resident
        } else if hSize == .regular, showComments, let aweme {
            sidePanel(aweme)
        }
    }

    private var resident: some View {
        VStack(spacing: 0) {
            if let aweme {
                authorBar(aweme)
                DYCommentPanel(bridge: bridge, aweme: aweme, onClose: nil)
                    .id(aweme.id)
            } else {
                ContentUnavailableView("还没有视频", systemImage: "play.rectangle", description: Text("推荐流加载后，这里显示作者和评论"))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassBackground())
        .modifier(DYRailReservedNudge())
    }

    private func authorBar(_ aweme: DYAweme) -> some View {
        Button(action: onAuthor) {
            HStack(spacing: 10) {
                CachedAsyncImage(url: aweme.author.avatar.flatMap(URL.init(string:))) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.primary.opacity(0.08)
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(aweme.author.name.isEmpty ? "作者" : aweme.author.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeTextPrimary)
                    if !aweme.desc.isEmpty {
                        Text(aweme.desc).font(.caption).foregroundStyle(.themeTextSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("douyin.duo.author")
    }

    private func sidePanel(_ aweme: DYAweme) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                DYCommentPanel(bridge: bridge, aweme: aweme, onClose: onClose)
                    .frame(width: min(380, geo.size.width * 0.36))
                    .id(aweme.id)
            }
        }
        .transition(.move(edge: .trailing))
    }
}

/// 外屏（非 regular）评论走系统 sheet，挂在 ArrangementView 外面，避免 sheet 被姿态容器吃掉。
struct DYOuterCommentSheet: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSize
    @Binding var showComments: Bool
    let aweme: DYAweme?
    let bridge: DouyinBridge

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { showComments && hSize != .regular && aweme != nil },
            set: { showComments = $0 }
        )) {
            if let aweme {
                DYCommentPanel(bridge: bridge, aweme: aweme, onClose: { showComments = false })
                    .presentationDetents([.fraction(0.62), .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

/// Observe a left pan on the containing window so nested ScrollViews do not swallow it.
/// The marker bounds and enabled flag keep covered screens and other panes out of scope.
enum DYSwipeDirection: CGFloat { case left = -1, right = 1 }

struct DYSwipeDismiss: UIViewRepresentable {
    var direction: DYSwipeDirection = .left
    var enabled = true
    let action: () -> Void

    func makeUIView(context: Context) -> Marker {
        let marker = Marker()
        marker.backgroundColor = .clear
        marker.coordinator = context.coordinator
        context.coordinator.marker = marker
        return marker
    }
    func updateUIView(_ view: Marker, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(to: view.window)
    }
    static func dismantleUIView(_ view: Marker, coordinator: Coordinator) { coordinator.attach(to: nil) }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Marker: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: DYSwipeDismiss
        weak var marker: Marker?
        weak var host: UIWindow?
        private lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            return pan
        }()
        init(_ parent: DYSwipeDismiss) { self.parent = parent }
        func attach(to window: UIWindow?) {
            guard host !== window else { return }
            host?.removeGestureRecognizer(pan)
            host = window
            window?.addGestureRecognizer(pan)
        }
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard parent.enabled, let marker, let window = marker.window,
                  !marker.isHidden, marker.convert(marker.bounds, to: window).contains(touch.location(in: window)) else { return false }
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard parent.enabled, let pan = gesture as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: host)
            return velocity.x * parent.direction.rawValue > 0 && abs(velocity.x) > abs(velocity.y) * 1.5
        }
        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        @objc private func swiped(_ gesture: UIPanGestureRecognizer) {
            guard parent.enabled, gesture.state == .ended else { return }
            let delta = gesture.translation(in: host)
            if delta.x * parent.direction.rawValue > 70, abs(delta.x) > abs(delta.y) * 1.5 { parent.action() }
        }
    }
}
