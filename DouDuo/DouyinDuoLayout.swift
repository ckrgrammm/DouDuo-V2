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

private struct DYCommentPanelReadyKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// 外屏展开期间先呈现轻量面板，动画完成后再填充评论和附加内容。
    var dyCommentPanelReady: Bool {
        get { self[DYCommentPanelReadyKey.self] }
        set { self[DYCommentPanelReadyKey.self] = newValue }
    }
}

private struct DYCommentsDockedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// 视频被评论面板挤到上方时为 true：视频页隐藏右侧按钮栏/文案，只留画面
    var dyCommentsDocked: Bool {
        get { self[DYCommentsDockedKey.self] }
        set { self[DYCommentsDockedKey.self] = newValue }
    }
}

/// 只由外屏 Dock 注入，内屏评论保留原有滚动行为。
struct DYCommentPullDismiss {
    var changed: (CGFloat) -> Void
    var ended: (CGFloat, CGFloat, Bool) -> Void
    /// 关闭按钮 / 右滑收起也走 Dock：先跑完位移动画，再改宿主状态（见 DYCommentDockModel.dismiss）
    var close: () -> Void
}
private struct DYCommentPullDismissKey: EnvironmentKey {
    static let defaultValue: DYCommentPullDismiss? = nil
}
extension EnvironmentValues {
    var dyCommentPullDismiss: DYCommentPullDismiss? {
        get { self[DYCommentPullDismissKey.self] }
        set { self[DYCommentPullDismissKey.self] = newValue }
    }
}

/// 观察评论列表自己的 pan，不另加一层手势与 ScrollView 争抢。
/// 只有手势从列表顶部向下开始时接管，正文中部仍正常滚动。
struct DYCommentScrollPullObserver: UIViewRepresentable {
    let callbacks: DYCommentPullDismiss?
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.callbacks = callbacks
        DispatchQueue.main.async { [weak view] in view?.attach() }
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView {
        var callbacks: DYCommentPullDismiss?
        private weak var scroll: UIScrollView?
        private var startedAtTop = false
        private var pulling = false
        private var savedBounces = true
        private var savedAlwaysBounce = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }
        func attach() {
            guard callbacks != nil else { detach(); return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let target = ancestor as? UIScrollView, target !== scroll else { return }
            detach()
            scroll = target
            savedAlwaysBounce = target.alwaysBounceVertical
            target.alwaysBounceVertical = true
            target.panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
        }
        func detach() {
            if let scroll {
                scroll.panGestureRecognizer.removeTarget(self, action: #selector(pan(_:)))
                if pulling { scroll.bounces = savedBounces }
                scroll.alwaysBounceVertical = savedAlwaysBounce
            }
            scroll = nil
            pulling = false
            startedAtTop = false
        }
        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            guard let scroll, let callbacks else { return }
            let delta = gesture.translation(in: scroll.window)
            let top = -scroll.adjustedContentInset.top
            switch gesture.state {
            case .began:
                let velocity = gesture.velocity(in: scroll.window)
                startedAtTop = scroll.contentOffset.y <= top + 1 && velocity.y > abs(velocity.x)
            case .changed:
                guard startedAtTop else { return }
                if !pulling, delta.y > 0 {
                    pulling = true
                    savedBounces = scroll.bounces
                    scroll.bounces = false
                }
                guard pulling else { return }
                scroll.contentOffset.y = top
                callbacks.changed(max(0, delta.y))
            case .ended, .cancelled, .failed:
                guard pulling else { startedAtTop = false; return }
                scroll.bounces = savedBounces
                pulling = false
                startedAtTop = false
                callbacks.ended(max(0, delta.y), gesture.velocity(in: scroll.window).y, gesture.state != .ended)
            default: break
            }
        }
    }
}

/// Dock 的动画状态。放在 @Observable 里而不是 Dock 自己的 @State：
/// 展开过程中状态会连续变几次（插入面板 → 启动位移 → 动画结束），
/// 如果由 Dock 的 body 读取，每次都会重新调用 `video()`、把整条视频流重建一遍，外屏上就是一顿一顿的。
/// 现在只有下面几个轻量 modifier / 小视图读取它，视频内容本身不参与重算。
@Observable
final class DYCommentDockModel {
    var drag: CGFloat = 0
    var panelVisible = false
    /// 仅复用当前视频的面板；关闭不销毁，切视频/离开外屏时释放。
    var panelMounted = false
    var mountedPanelID: String?
    /// 视频页是否隐藏按钮栏/文案。收起动画结束后才置回 false：
    /// 它一变，所有已加载的视频页都要重算，放在动画中途就是掉帧。
    var docked = false
    var presentation: CGFloat = 0
    var panelReady = false
    /// 键盘上沿（全局坐标），没有键盘时为 +∞
    var keyboardTop: CGFloat = .infinity
    /// 窗口顶部安全区。⚠️ 不能在 body 里直接读 UIWindow.safeAreaInsets：
    /// 更新过程中读它会让 UIKit 重入布局宿主窗口，外屏上整个 SwiftUI 就停在首帧（一直「连接抖音…」、点不动）。
    /// 所以只在出现/开关评论时读一次存起来。
    var windowTop: CGFloat = 0
    @ObservationIgnored var wantsOpen = false
    @ObservationIgnored private var animationID = 0
    @ObservationIgnored private var dismissing = false

    /// Dock 自己发起的收起（下拉 / 点上方视频）：先只跑位移动画，到位后才 `commit` 改宿主的 isOpen。
    /// 宿主那个状态一变，整个视频流和评论面板都要重算一遍；松手那一帧就改会正好卡在动画起步，
    /// 挪到面板滑出屏幕之后，画面静止时再做就看不出来。
    func dismiss(commit: @escaping () -> Void) {
        guard wantsOpen, !dismissing else { return }
        dismissing = true
        animationID += 1
        let request = animationID
        withAnimation(.smooth(duration: 0.25), completionCriteria: .logicallyComplete) {
            presentation = 0
        } completion: { [self] in
            dismissing = false
            // 期间宿主已经自己关了（切视频等），收尾由那边的动画负责
            guard request == animationID else { return }
            commit()
        }
    }

    /// 面板已在屏幕外：隐藏面板并恢复视频控件，保留当前视频的评论状态。
    func finishClose() {
        panelVisible = false
        panelReady = false
        docked = false
        drag = 0
    }

    func releasePanel() {
        animationID += 1
        dismissing = false
        wantsOpen = false
        presentation = 0
        finishClose()
        panelMounted = false
        mountedPanelID = nil
    }

    func animatePresentation(_ open: Bool) {
        animationID += 1
        let request = animationID
        // 位移到位（逻辑完成）就收尾，不等弹簧尾巴完全静止：
        // 展开时空面板不用多挂几百毫秒；收起时面板已在屏幕外，隐藏并保留列表。
        withAnimation(.smooth(duration: 0.25), completionCriteria: .logicallyComplete) {
            presentation = open ? 1 : 0
            if open { drag = 0 }
        } completion: { [self] in
            guard request == animationID else { return }
            if open && wantsOpen {
                panelReady = true
            } else if !open && !wantsOpen {
                finishClose()
            }
        }
    }

    func updateDrag(_ distance: CGFloat, limit: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag = min(limit, max(0, distance)) }
    }

    func finishDrag(distance: CGFloat, projected: CGFloat, limit: CGFloat, cancelled: Bool = false,
                    close: () -> Void) {
        if !cancelled && (distance > limit * 0.25 || projected > limit * 0.45) {
            close()
        } else {
            withAnimation(.smooth(duration: 0.25)) { drag = 0 }
        }
    }

    func dragGesture(_ panelH: CGFloat, close: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { [self] v in updateDrag(v.translation.height, limit: panelH) }
            .onEnded { [self] v in
                finishDrag(distance: v.translation.height, projected: v.predictedEndTranslation.height,
                           limit: panelH, close: close)
            }
    }
}

/// Dock 容器的几何量（由外层 GeometryReader 算一次传下来）。
private struct DYCommentDockMetrics {
    let size: CGSize
    let safeTop: CGFloat
    let globalMaxY: CGFloat
    var panelH: CGFloat { (size.height * 0.68).rounded() }

    /// 宿主普遍忽略顶部安全区（geo 里读到 0），兜底用窗口的，让缩小后的视频躲开状态栏/灵动岛
    func top(_ model: DYCommentDockModel) -> CGFloat { max(safeTop, model.windowTop) }
    /// 0 = 全屏视频，1 = 面板完全展开
    func progress(_ model: DYCommentDockModel, enabled: Bool) -> CGFloat {
        enabled ? model.presentation * max(0, min(1, (panelH - model.drag) / panelH)) : 0
    }
    func lift(_ model: DYCommentDockModel) -> CGFloat { max(0, globalMaxY - model.keyboardTop) }
    func frameH(_ model: DYCommentDockModel) -> CGFloat {
        max(0, min(panelH, size.height - lift(model) - top(model)))
    }
}

/// 视频层的缩放/上移。body 只拿到 content 占位，动画状态变化不会重算视频内容。
private struct DYCommentDockVideoModifier: ViewModifier {
    let model: DYCommentDockModel
    let enabled: Bool
    let open: Bool
    let metrics: DYCommentDockMetrics

    func body(content: Content) -> some View {
        let h = metrics.size.height
        let top = metrics.top(model)
        let progress = metrics.progress(model, enabled: enabled)
        let scale = max(0.05, (h - metrics.panelH * progress - top * progress) / h)
        content
            .frame(width: metrics.size.width, height: h)
            .environment(\.dyCommentsDocked, enabled && model.docked)
            // 只让外层 transform 动；不把 docked 的动画传进视频、文字和按钮栏。
            .transaction {
                if enabled { $0.animation = nil; $0.disablesAnimations = true }
            }
            .scaleEffect(scale, anchor: .top)
            .offset(y: top * progress)
            .allowsHitTesting(!open)
    }
}

/// 面板外壳：圆角、把手、底部补色和位移。同样只包 content 占位，不重算评论面板。
private struct DYCommentDockPanelModifier: ViewModifier {
    let model: DYCommentDockModel
    let enabled: Bool
    let isOpen: Bool
    let metrics: DYCommentDockMetrics
    let close: () -> Void

    func body(content: Content) -> some View {
        let w = metrics.size.width, h = metrics.size.height
        let panelH = metrics.panelH
        let progress = metrics.progress(model, enabled: enabled)
        let lift = metrics.lift(model)
        let frameH = metrics.frameH(model)
        VStack(spacing: 0) {
            content
                // 收起过程中保持 ready 不变：此刻翻转会让整个评论列表在动画第一帧重算一遍。
                .environment(\.dyCommentPanelReady, model.panelReady)
                // 评论数据到达时不继承外层的展开动画，避免整批行参与插入动画。
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .frame(width: w, height: frameH)
            // 宿主底部不一定铺到 Home 指示条下面：补一截同色底，免得面板下方露黑边
            Rectangle().fill(Color(uiColor: .systemBackground)).frame(width: w, height: 120)
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
                    .gesture(model.dragGesture(panelH, close: close))
            }
            .offset(y: h - lift - frameH + panelH * (1 - progress))
    }
}

/// 面板上方的视频区：点一下收起，也能往下拖
private struct DYCommentDockDismissArea: View {
    let model: DYCommentDockModel
    let enabled: Bool
    let metrics: DYCommentDockMetrics
    let close: () -> Void

    var body: some View {
        let shown = metrics.panelH * metrics.progress(model, enabled: enabled)
        Color.black.opacity(0.001)
            .frame(width: metrics.size.width, height: max(0, metrics.size.height - shown))
            .contentShape(Rectangle())
            .onTapGesture { close() }
            .gesture(model.dragGesture(metrics.panelH, close: close))
            .accessibilityLabel("收起评论")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("douyin.comments.dockDismiss")
    }
}

/// 保持内容挂载，仅改变可见性与交互；关闭面板不能继续截获触摸或暴露无障碍元素。
private struct DYCommentDockVisibilityModifier: ViewModifier {
    let model: DYCommentDockModel
    func body(content: Content) -> some View {
        content
            .opacity(model.panelVisible ? 1 : 0)
            .allowsHitTesting(model.panelVisible)
            .accessibilityHidden(!model.panelVisible)
    }
}

/// 当前视频面板的挂载/释放；可见性变化由独立 modifier 处理。
private struct DYCommentDockPanelHost<Panel: View>: View {
    let model: DYCommentDockModel
    let panelID: String?
    let enabled: Bool
    @Binding var isOpen: Bool
    let metrics: DYCommentDockMetrics
    @ViewBuilder var panel: () -> Panel

    var body: some View {
        if enabled && model.panelMounted && model.mountedPanelID == panelID {
            let panelH = metrics.panelH
            let close = { model.dismiss { isOpen = false } }
            DYCommentDockDismissArea(model: model, enabled: enabled, metrics: metrics, close: close)
                .modifier(DYCommentDockVisibilityModifier(model: model))
            panel()
                .environment(\.dyCommentPullDismiss, DYCommentPullDismiss(
                    changed: { [model] in model.updateDrag($0, limit: panelH) },
                    ended: { [model] distance, velocity, cancelled in
                        model.finishDrag(distance: distance, projected: distance + velocity * 0.2,
                                         limit: panelH, cancelled: cancelled, close: close)
                    },
                    close: close))
                .modifier(DYCommentDockPanelModifier(model: model, enabled: enabled, isOpen: isOpen,
                                                     metrics: metrics, close: close))
                .modifier(DYCommentDockVisibilityModifier(model: model))
                .transition(.identity)
                .onAppear {
                    // 先让面板在屏幕外完成首轮布局，再启动位移动画。
                    DispatchQueue.main.async {
                        if isOpen { model.animatePresentation(true) }
                    }
                }
                .accessibilityIdentifier("douyin.comments.dock")
        }
    }
}

/// 外屏评论（仿官方）：面板从底部升起占约 2/3 高，视频整体等比缩小、移到面板上方继续播放；
/// 下拉面板顶部时视频跟手放大，松手过 1/4 或甩得快就收起，点上方视频也收起。
/// 视频本身的布局尺寸始终不变（只做缩放变换），所以开关评论不会重排/重建播放器。
struct DYCommentDock<Video: View, Panel: View>: View {
    /// 当前姿态是否走「视频 + 评论」联动（内屏并排/桌面模式时为 false，直接透传）
    var panelID: String? = nil
    let enabled: Bool
    @Binding var isOpen: Bool
    @ViewBuilder var video: () -> Video
    @ViewBuilder var panel: () -> Panel
    /// ⚠️ body 里不要读 model 的属性：一读，展开动画的每次状态变化都会重新调用 video()。
    @State private var model = DYCommentDockModel()

    private static var windowTopInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        return window?.safeAreaInsets.top ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            let metrics = DYCommentDockMetrics(size: geo.size, safeTop: geo.safeAreaInsets.top,
                                               globalMaxY: geo.frame(in: .global).maxY)
            ZStack(alignment: .topLeading) {
                video()
                    .modifier(DYCommentDockVideoModifier(model: model, enabled: enabled,
                                                         open: enabled && isOpen, metrics: metrics))
                DYCommentDockPanelHost(model: model, panelID: panelID, enabled: enabled, isOpen: $isOpen,
                                       metrics: metrics, panel: panel)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .onAppear {
            let model = model
            let open = isOpen
            model.wantsOpen = open
            DispatchQueue.main.async {
                model.windowTop = Self.windowTopInset
                model.panelVisible = model.wantsOpen
                model.mountedPanelID = panelID
                model.panelMounted = model.wantsOpen
                model.docked = model.wantsOpen
                model.presentation = 0
                model.panelReady = false
            }
        }
        .onChange(of: isOpen) { _, open in
            model.wantsOpen = open
            if open {
                model.mountedPanelID = panelID
                model.windowTop = Self.windowTopInset
                if model.panelVisible {
                    model.docked = true
                    model.animatePresentation(true)
                } else {
                    // 面板首次插入不能与最终 offset 合并，否则看起来会直接跳到终点。
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        model.presentation = 0
                        model.drag = 0
                        model.panelVisible = true
                        model.docked = true
                    }
                    if model.panelMounted {
                        // 复用面板不会再次 onAppear，单独启动本次展开。
                        DispatchQueue.main.async {
                            if model.wantsOpen { model.animatePresentation(true) }
                        }
                    } else {
                        model.panelMounted = true
                    }
                }
            } else if model.presentation == 0 {
                // Dock 自己已经把面板滑出去了，直接收尾
                model.finishClose()
            } else {
                model.animatePresentation(false)
            }
        }
        .onChange(of: panelID) { _, id in
            // Host 同时校验 ID，避免 onChange 执行前先为新视频创建一帧隐藏面板。
            if !isOpen { model.releasePanel() }
            else { model.mountedPanelID = id }
        }
        .onChange(of: enabled) { _, active in
            if !active {
                model.releasePanel()
            } else if isOpen {
                model.mountedPanelID = panelID
                model.wantsOpen = true
                model.windowTop = Self.windowTopInset
                model.panelVisible = true
                model.docked = true
                model.panelMounted = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            withAnimation(.snappy) { model.keyboardTop = f.height > 0 ? f.minY : .infinity }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.snappy) { model.keyboardTop = .infinity }
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
    var alignToCameraAxis = false

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            DYRailReservedNudgeBox(alignToCameraAxis: alignToCameraAxis) { content }
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct DYRailReservedNudgeBox<Content: View>: View {
    let alignToCameraAxis: Bool
    @ViewBuilder var content: () -> Content
    @State private var nudge: CGSize = .zero

    var body: some View {
        content()
            .offset(nudge)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: DYNudgePref.self,
                                           value: DYReservedNudge.offset(in: proxy, alignToCameraAxis: alignToCameraAxis))
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
    static func offset(in proxy: GeometryProxy, alignToCameraAxis: Bool = false) -> CGSize {
        let local = CGRect(origin: .zero, size: proxy.size)
        guard local.width > 1, local.height > 1 else { return .zero }
        var box = local
        var acc = CGSize.zero
        // The reserved strip's midpoint is not necessarily the system controls' axis.
        // On the outer display, use the actual camera/Dynamic Island region instead.
        if alignToCameraAxis,
           let camera = proxy.reservedRegions(kind: .occlusion)
            .filter({ $0.isActive && $0.frame.width > 1 && $0.frame.height > 1
                && $0.frame.minY < 0
                && abs($0.frame.midX - local.midX) < max(100, local.width) })
            .min(by: { abs($0.frame.midX - local.midX) < abs($1.frame.midX - local.midX) }) {
            acc.width = camera.frame.midX - local.midX
            box = box.offsetBy(dx: acc.width, dy: 0)
        }
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
