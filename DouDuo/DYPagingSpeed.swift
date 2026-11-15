import SwiftUI
import UIKit

/// 竖滑分页收尾（移植自上游 1.5.2）：拖过 1/4 屏或明确快甩才翻页；下一条没就绪就弹回；
/// 收尾 0.16–0.22s 推上来，停稳之后才切当前条（停住才起播）。
/// Short-video paging only. Standard leaves SwiftUI's delegate and animation untouched.
enum DYPagingSpeed: String, CaseIterable, Identifiable {
    static let key = "douyin_paging_speed_v1"
    case standard, fast, faster
    var id: String { rawValue }
    var title: String {
        switch self { case .standard: "标准（系统）"; case .fast: "快速"; case .faster: "更快" }
    }
    var duration: TimeInterval? {
        switch self { case .standard: nil; case .fast: 0.18; case .faster: 0.10 }
    }
    static func resolved(_ raw: String) -> Self { Self(rawValue: raw) ?? .standard }
}

/// Attach inside the ScrollView, on its content stack, so it cannot affect nested comment/image scrolls.
struct DYPagingSpeedBridge: UIViewRepresentable {
    let ids: [String]
    @Binding var currentID: String?
    /// 能不能翻过去（默认查 DYReadiness）。推荐流里的直播卡等非视频页可以直接放行。
    var isReady: (String) -> Bool = { DYReadiness.isReady($0) }
    /// 收尾动画停住时调用；不传就直接改 currentID。推荐流要在这里处理离开直播卡等收尾逻辑。
    var onSettle: ((String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 维护者定稿：固定「更快」（0.10s），不提供菜单。系统开了「减少动态效果」时仍走系统分页。
    static let fixedSpeed: DYPagingSpeed = .faster
    func makeUIView(context: Context) -> DYPagingSpeedHost { DYPagingSpeedHost() }
    func updateUIView(_ view: DYPagingSpeedHost, context: Context) {
        let listChanged = view.ids != ids
        view.ids = ids
        view.currentID = currentID
        if listChanged { view.reconcileAfterLayout() }
        let settle = onSettle
        view.didSettle = { id in
            guard ids.contains(id) else { return }
            if let settle { settle(id); return }
            guard currentID != id else { return }
            currentID = id
        }
        view.isReady = isReady
        view.duration = reduceMotion ? nil : Self.fixedSpeed.duration
        view.attachWhenReady()
    }
    static func dismantleUIView(_ view: DYPagingSpeedHost, coordinator: ()) { view.detach() }
}

final class DYPagingSpeedHost: UIView {
    var duration: TimeInterval?
    var ids: [String] = []
    var currentID: String?
    var didSettle: (String) -> Void = { _ in }
    var isReady: (String) -> Bool = { DYReadiness.isReady($0) }
    private var proxy: DYPagingDelegate?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detach() } else { attachWhenReady() }
    }
    func attachWhenReady() {
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }
    private func attach() {
        guard window != nil else { return }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroll = ancestor as? UIScrollView else { return }
        if proxy?.scroll !== scroll || (proxy != nil && scroll.delegate !== proxy) { detach() }
        guard let duration else { detach(); return }
        if let proxy { proxy.duration = duration; return }
        // Never chain multiple owners or touch a horizontal/non-paging scroll view.
        guard scroll.isPagingEnabled, !(scroll.delegate is DYPagingDelegate) else { return }
        let next = DYPagingDelegate(scroll: scroll, duration: duration,
            ids: { [weak self] in self?.ids ?? [] },
            currentID: { [weak self] in self?.currentID },
            isReady: { [weak self] id in self?.isReady(id) ?? true },
            didSettle: { [weak self] id in self?.didSettle(id) })
        proxy = next
        scroll.delegate = next
        #if DEBUG
        ddWrite("DDPAGE attach duration=\(duration)")
        #endif
    }
    func reconcileAfterLayout() { proxy?.reconcileAfterLayout() }
    func detach() { proxy?.detach(); proxy = nil }
}

private final class DYPagingDisplayTarget: NSObject {
    weak var owner: DYPagingDelegate?
    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}

/// Preserves SwiftUI's target selection and all optional delegate methods. Only settling changes.
private final class DYPagingDelegate: NSObject, UIScrollViewDelegate {
    weak var scroll: UIScrollView?
    private weak var original: UIScrollViewDelegate?
    var duration: TimeInterval
    private let ids: () -> [String]
    private let currentID: () -> String?
    private let isReady: (String) -> Bool
    private let didSettle: (String) -> Void
    private var targetID: String?
    /// 收尾动画期间「应该在的位置」；SwiftUI 的 scrollPosition 在抬手切当前页时会把列表直接跳到终点，
    /// 下一帧动画又拉回中途 → 肉眼看到「往回跳一帧」。动画期间外部写入一律在同一帧内改回来。
    private var expected: CGPoint?
    private var writing = false
    private var jumpFixes = 0
    /// 每条被拦次数（同一条拦太多就放行，避免永久卡住）
    private var blockedCount: [String: Int] = [:]
    private var target: CGPoint?
    private var start = CGPoint.zero
    private var startTime: CFTimeInterval = 0
    private var animationDuration: TimeInterval = 0
    private var link: CADisplayLink?
    private let displayTarget = DYPagingDisplayTarget()
    private var boundsObservation: NSKeyValueObservation?
    private var size = CGSize.zero

    init(scroll: UIScrollView, duration: TimeInterval, ids: @escaping () -> [String],
         currentID: @escaping () -> String?, isReady: @escaping (String) -> Bool,
         didSettle: @escaping (String) -> Void) {
        self.ids = ids; self.currentID = currentID; self.isReady = isReady; self.didSettle = didSettle
        self.scroll = scroll; self.original = scroll.delegate; self.duration = duration
        self.size = scroll.bounds.size
        super.init()
        displayTarget.owner = self
        scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
        boundsObservation = scroll.observe(\.bounds, options: [.new]) { [weak self] view, _ in
            guard let self, view.bounds.size != self.size else { return }
            self.size = view.bounds.size
            self.reconcileAfterLayout()
        }
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? { original }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        original?.scrollViewDidScroll?(scrollView)
        guard link != nil, !writing, let e = expected, abs(scrollView.contentOffset.y - e.y) > 0.5 else { return }
        writing = true
        scrollView.setContentOffset(e, animated: false)
        writing = false
        jumpFixes += 1
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        stop()
        original?.scrollViewWillBeginDragging?(scrollView)
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        original?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity,
                                            targetContentOffset: targetContentOffset)
        guard scrollView.isPagingEnabled, scrollView.bounds.height > 0,
              targetContentOffset.pointee.y.isFinite else { return }
        let items = ids()
        let h = scrollView.bounds.height
        let top = scrollView.adjustedContentInset.top
        let curIndex0 = items.firstIndex(where: { $0 == currentID() })
            ?? Int(((scrollView.contentOffset.y + top) / h).rounded())
        // 翻页规则自己定（系统分页轻轻一碰就翻）：拖过 1/4 屏，或明确快甩，才翻到下一条/上一条；否则弹回原位
        let dragged = (scrollView.contentOffset.y + top) - CGFloat(curIndex0) * h
        let flick = abs(velocity.y) > 0.6
        var index = curIndex0
        if dragged > h * 0.25 || (flick && velocity.y > 0 && dragged > 0) { index = curIndex0 + 1 }
        else if dragged < -h * 0.25 || (flick && velocity.y < 0 && dragged < 0) { index = curIndex0 - 1 }
        index = min(max(index, 0), max(items.count - 1, 0))
        targetContentOffset.pointee.y = CGFloat(index) * h - top
        guard items.indices.contains(index) else { return }
        // 老板要求：下一个视频还没加载好就别让它翻过去（跟抖音原版一样）
        // 只拦「往前翻」；往回翻是看过的，直接放行
        let curIndex = items.firstIndex(where: { $0 == currentID() }) ?? index
        if index > curIndex, !isReady(items[index]) {
            let id = items[index]
            blockedCount[id, default: 0] += 1
            // 同一条拦了 3 次还没就绪，就放行（可能是地址失效/长视频加载慢；宁可黑一下也不能把人卡死）
            if blockedCount[id, default: 0] <= 3 {
                let curY = CGFloat(curIndex) * scrollView.bounds.height - scrollView.adjustedContentInset.top
                targetID = items[curIndex]
                target = CGPoint(x: scrollView.contentOffset.x, y: curY)
                targetContentOffset.pointee = scrollView.contentOffset
                DYLiveModel.log("DDBLOCK next=\(id.suffix(4)) 未就绪，弹回当前页 #\(blockedCount[id, default: 0])")
                return
            }
            DYLiveModel.log("DDFORCE next=\(id.suffix(4)) 拦了 3 次仍未就绪，放行")
        }
        targetID = items[index]
        target = targetContentOffset.pointee
        // Prevent system deceleration; CADisplayLink then moves to the system-selected page.
        targetContentOffset.pointee = scrollView.contentOffset
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        original?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
        guard target != nil else { return }
        start = scrollView.contentOffset; startTime = CACurrentMediaTime()
        expected = start; jumpFixes = 0
        // 剩余距离越长越久（0.22–0.32s），不再固定 0.10s 一闪而过
        if let t = target {
            let remain = abs(t.y - scrollView.contentOffset.y) / max(scrollView.bounds.height, 1)
            // 停住才起播后，收尾时长就是起播等待：0.22–0.32s 实测 lift→active≈320ms，老板觉得「又慢了」。
            // 收到 0.16–0.22s：仍是推上来的减速，不是 0.10s 的闪
            animationDuration = 0.16 + 0.06 * Double(min(remain, 1))
        } else { animationDuration = duration }
        let next = CADisplayLink(target: displayTarget, selector: #selector(DYPagingDisplayTarget.tick(_:)))
        link = next; next.add(to: .main, forMode: .common)
        // 老板定：下一条完全滑到位、停住才开始播（不再抬手就起播，那样画面还在往上走就已经开播）。
        // 切当前页统一放到收尾动画结束的 didSettle 里。

    }
    @objc private func panChanged(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .cancelled || gesture.state == .failed {
            // A cancelled gesture must never commit the previous gesture's target.
            reconcileAfterLayout()
        }
    }
    func tick(_ displayLink: CADisplayLink) {
        guard let scroll, let capturedTarget = target, let targetID,
              let index = ids().firstIndex(of: targetID), scroll.delegate === self,
              !scroll.isDragging, scroll.window != nil else { stop(); return }
        // Re-resolve the stable item, never write an index captured from an older list.
        let target = CGPoint(x: capturedTarget.x,
                             y: CGFloat(index) * scroll.bounds.height - scroll.adjustedContentInset.top)
        let fraction = min(1, max(0, (CACurrentMediaTime() - startTime) / animationDuration))
        let progress = 1 - pow(1 - fraction, 3)
        let p = CGPoint(x: start.x + (target.x - start.x) * progress,
                        y: start.y + (target.y - start.y) * progress)
        expected = p
        writing = true
        scroll.setContentOffset(p, animated: false)
        writing = false
        if fraction >= 1 {
            if jumpFixes > 0 { DYLiveModel.log("DDJUMPFIX 收尾期间拦下外部跳位 \(jumpFixes) 次") }
            stop()
            // SwiftUI may suppress its final scrollPosition write when there is no native deceleration.
            #if DEBUG
            ddWrite("DDPAGE settle id=\(targetID) ms=\(Int((CACurrentMediaTime() - startTime) * 1000))")
            #endif
            DYLiveModel.log("DDSETTLE \(targetID.suffix(6)) 停住才起播 \(Int((CACurrentMediaTime() - startTime) * 1000))ms")
            didSettle(targetID)
        }
    }
    func reconcileAfterLayout() {
        stop()
        DispatchQueue.main.async { [weak self] in
            guard let self, let scroll = self.scroll, scroll.delegate === self,
                  !scroll.isDragging, let id = self.currentID(),
                  let index = self.ids().firstIndex(of: id) else { return }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                y: CGFloat(index) * scroll.bounds.height - scroll.adjustedContentInset.top), animated: false)
        }
    }
    private func stop() { link?.invalidate(); link = nil; target = nil; targetID = nil; expected = nil }
    func detach() {
        stop()
        boundsObservation?.invalidate(); boundsObservation = nil
        guard let scroll else { return }
        scroll.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
        if scroll.delegate === self {
            scroll.delegate = original
            // Restore the currently bound page, not an unfinished gesture's old destination.
            if !scroll.isDragging, let id = currentID(), let index = ids().firstIndex(of: id) {
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                    y: CGFloat(index) * scroll.bounds.height - scroll.adjustedContentInset.top), animated: false)
            }
        }
    }
    deinit { link?.invalidate() }
}

/// 给「scrollPosition 直接绑当前条」的竖滑列表（关注流、作品/喜欢/收藏点进去的列表）用：
/// 滚动位置和当前条拆开——滑过中线不再切当前条开播，只在分页收尾停住时（DYPagingSpeedBridge）切。
/// 配合 LazyVStack 上的 `.background(DYPagingSpeedBridge(ids:currentID:))` 使用。
struct DYSettledPaging: ViewModifier {
    @Binding var currentID: String?
    var anchor: UnitPoint = .top
    @State private var scrollID: String?
    @State private var fallback: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let base = content
            .scrollPosition(id: $scrollID, anchor: anchor)
            .onAppear { scrollID = currentID }
            .onChange(of: currentID) { _, id in if scrollID != id { scrollID = id } }
            .onChange(of: scrollID) { _, id in
                // 减少动态效果时分页桥不接管，沿用系统的停住即切
                guard reduceMotion, let id, id != currentID else { return }
                currentID = id
            }
        if #available(iOS 18.0, *) {
            base.onScrollPhaseChange { _, phase in
                guard phase == .idle, !reduceMotion else { fallback?.cancel(); return }
                // 兜底：分页桥万一没接上（没触发 settle），停稳后按实际位置切当前条，别卡在上一条
                fallback?.cancel()
                fallback = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled, let s = scrollID, s != currentID else { return }
                    DYLiveModel.log("DDSETTLE-FALLBACK \(s.suffix(6))")
                    currentID = s
                }
            }
        } else {
            base
        }
    }
}
