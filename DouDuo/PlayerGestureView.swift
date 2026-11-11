import SwiftUI
import UIKit

// MARK: - UIKit 手势宿主：Pan 起手定方向（横=快进/竖=漏给 ScrollView 切视频）+ 单击/双击/长按
// 纯 SwiftUI 的 .gesture/.simultaneousGesture 会吞掉整段手势序列导致竖滑分页失效；
// 下沉 UIKit 用一个 UIPanGestureRecognizer，在 shouldBegin 里按起手速度方向仲裁：
//   · 横向主导 → 本次手势归 seek（我们接管）
//   · 纵向主导 → return false，手势漏给外层 ScrollView 分页切视频
// 起手那一帧定轴，整段锁死，中途不改（=你说的"一发力就定方向"）。
struct PlayerGestureView: UIViewRepresentable {
    var onSingleTap: () -> Void
    var onDoubleTap: (CGFloat, CGFloat) -> Void          // (触点x, 宽度)
    var onLongPress: (Bool) -> Void                       // pressing
    /// 小红书同款：长按 2 倍速后手指下滑一段 → 锁定 2 倍速（松手也不恢复）
    var onLongPressLock: () -> Void = {}
    /// 长按后手指上滑一段 → 取消锁定、恢复 1 倍
    var onLongPressUnlock: () -> Void = {}
    var onSeekBegan: () -> Void
    var onSeekChanged: (CGFloat, CGFloat) -> Void         // (横向位移, 宽度)
    var onSeekEnded: () -> Void
    var onEdgeChanged: (CGFloat) -> Void = { _ in }        // 左缘右滑过程中：位移跟手
    var onEdgeEnded: (CGFloat, CGFloat, CGFloat) -> Void = { _, _, _ in }  // 松手：(位移, 横向速度, 屏宽)
    /// 竖向优先（抖音短视频：上下滑切视频是主操作，只有明显横向才算快进）；影库保持横向偏置
    var verticalFirst = false
    /// Feed navigation takes left swipes; bottom progress-bar seeking stays independent.
    var onSwipeLeft: (() -> Void)? = nil
    var onSwipeRight: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        let c = context.coordinator
        c.view = v

        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleSingle(_:)))
        single.numberOfTapsRequired = 1
        single.delegate = c

        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDouble(_:)))
        double.numberOfTapsRequired = 2
        double.delegate = c
        single.require(toFail: double)

        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleLong(_:)))
        long.minimumPressDuration = 0.5
        long.allowableMovement = 12     // 手指移动超 12pt（横滑/竖滑）→ 长按取消，让位给 pan/分页
        long.delegate = c
        c.long = long

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = c
        c.pan = pan

        // 屏幕左缘右滑退出（系统级边缘手势，只在最左 ~20pt 触发，不抢中间区域）
        let edge = UIScreenEdgePanGestureRecognizer(target: c, action: #selector(Coordinator.handleEdge(_:)))
        edge.edges = .left
        edge.delegate = c
        c.edge = edge
        pan.require(toFail: edge)

        v.addGestureRecognizer(single)
        v.addGestureRecognizer(double)
        v.addGestureRecognizer(long)
        v.addGestureRecognizer(pan)
        v.addGestureRecognizer(edge)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self   // 刷新闭包，回调读到最新 @State
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerGestureView
        weak var view: UIView?
        weak var pan: UIPanGestureRecognizer?
        weak var edge: UIScreenEdgePanGestureRecognizer?
        weak var long: UILongPressGestureRecognizer?
        private var navigationDirection: CGFloat = 0
        private var pressStartY: CGFloat = 0
        private var pressLocked = false
        private weak var frozenScroll: UIScrollView?
        init(_ p: PlayerGestureView) { parent = p }

        @objc func handleSingle(_ g: UITapGestureRecognizer) { parent.onSingleTap() }

        @objc func handleDouble(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            parent.onDoubleTap(g.location(in: v).x, v.bounds.width)
        }

        @objc func handleLong(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                parent.onLongPress(true)
                pressStartY = g.location(in: view).y; pressLocked = false
                // 长按期间下滑不能触发外层切视频：先把外层 ScrollView 的滑动关掉，松手再恢复
                var p = view?.superview
                while let x = p, !(x is UIScrollView) { p = x.superview }
                if let sv = p as? UIScrollView { sv.panGestureRecognizer.isEnabled = false; frozenScroll = sv }
            case .changed:
                let dy = g.location(in: view).y - pressStartY
                if !pressLocked, abs(dy) > 50 {
                    pressLocked = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if dy > 0 { parent.onLongPressLock() } else { parent.onLongPressUnlock() }
                }
            case .ended, .cancelled, .failed:
                frozenScroll?.panGestureRecognizer.isEnabled = true; frozenScroll = nil
                parent.onLongPress(false)
            default: break
            }
        }

        @objc func handleEdge(_ g: UIScreenEdgePanGestureRecognizer) {
            guard let v = view else { return }
            let dx = g.translation(in: v).x
            switch g.state {
            case .began:
                parent.onEdgeChanged(0)
            case .changed:
                parent.onEdgeChanged(max(0, dx))      // 跟手位移上报给容器，画面 1:1 右移
            case .ended, .cancelled, .failed:
                parent.onEdgeEnded(max(0, dx), g.velocity(in: v).x, v.bounds.width)
            default: break
            }
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = view else { return }
            if navigationDirection != 0 {
                if g.state == .ended {
                    let delta = g.translation(in: v)
                    let threshold = max(60, min(120, v.bounds.width * 0.15))
                    if delta.x * navigationDirection >= threshold, abs(delta.x) > abs(delta.y) * 1.2 {
                        if navigationDirection < 0 { parent.onSwipeLeft?() } else { parent.onSwipeRight?() }
                    }
                }
                if g.state == .ended || g.state == .cancelled || g.state == .failed { navigationDirection = 0 }
                return
            }
            switch g.state {
            case .began: parent.onSeekBegan()
            case .changed: parent.onSeekChanged(g.translation(in: v).x, v.bounds.width)
            case .ended, .cancelled, .failed: parent.onSeekEnded()
            default: break
            }
        }

        // 方向仲裁：Pan 起手定轴。横向偏置——除非竖向明显主导才让给 ScrollView 切视频，
        // 否则都判为快进，避免快进时带点下滑分量被误识别成切视频。

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g is UIScreenEdgePanGestureRecognizer { return true }   // 边缘退出始终允许
            guard let pg = g as? UIPanGestureRecognizer, let v = view else { return true }
            // 长按（2 倍速）期间不触发快进
            if let l = long, l.state == .began || l.state == .changed { return false }
            let vel = pg.velocity(in: v)
            // 底部 ~64pt 留给底部进度条手势，避免与全屏横滑重复触发
            let start = pg.location(in: v)
            if start.y > v.bounds.height - 64 { return false }
            // 起手那一帧速度可能是 0（0 >= 0 会被误判成快进，竖滑切不了视频）→ 退回用位移判方向；都为 0 让给分页
            var d = vel
            if abs(d.x) < 1, abs(d.y) < 1 { d = pg.translation(in: v) }
            if abs(d.x) < 0.5, abs(d.y) < 0.5 { return false }
            navigationDirection = abs(d.x) > abs(d.y) * 1.2
                ? (d.x < 0 && parent.onSwipeLeft != nil ? -1 : d.x > 0 && parent.onSwipeRight != nil ? 1 : 0) : 0
            if parent.verticalFirst {
                // 横向要比竖向大 20% 才算快进，其余一律交给分页切视频
                return abs(d.x) > abs(d.y) * 1.2
            }
            // 竖向速度要比横向大 50% 以上才算"切视频"，否则一律快进（横向偏置，抗误判）
            return abs(d.x) * 1.5 >= abs(d.y)
        }

        // 手势互斥：Pan 已激活（横向快进）→ 独占，不允许 ScrollView 同时响应
        // Pan 被拒绝（竖向）→ 返回 true 让 ScrollView 接管分页
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if let pg = pan, pg.state == .began || pg.state == .changed {
                return false   // 正在拖进度，独占
            }
            return true        // Pan 还没开始或已结束，让 ScrollView 自由分页
        }
    }
}
