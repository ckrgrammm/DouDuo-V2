// DouDuo 顶部导航栏。推荐 / 关注 / 直播共用这一条：页面只提供当前页、角标和动作（DYNavBarModel），
// 摆放规则（DYNavBarPlacement）只看屏幕姿态，不看当前是哪一页，所以切页时各入口位置不变。
// 从 DouyinFeedView.swift 抽出，排法与原实现一致。
import SwiftUI

// MARK: - 输入

/// 顶栏的全部输入。
struct DYNavBarModel {
    var tab: DYTab
    var refreshing = false
    var noticeUnread = 0
    var avatar: URL? = nil
    var select: (DYTab) -> Void
    /// 双击「推荐」：切回推荐并刷新
    var refreshRecommend: () -> Void
    var openMine: () -> Void
    var openMessages: () -> Void
    var openSearch: () -> Void
}

/// 顶栏在屏幕上的摆放。只由屏幕姿态和安全区决定。
struct DYNavBarPlacement {
    /// A · 经典布局已下线，恒为 true；保留开关是为了经典排法的代码还能走到。
    let immersive: Bool
    /// 外屏（右侧系统条）和内屏用居中顶栏；普通 iPhone 竖屏保持左排
    let centered: Bool
    /// 内屏：「推荐」对齐折痕（屏幕正中），顶栏横跨整屏、不让右侧按钮列
    let hingeCentered: Bool
    /// 内屏竖放：顶栏和右上角时间 / 电量同一行
    let statusRow: Bool
    /// 顶栏右侧让出的宽度，与视频区右侧按钮列一致
    let railReserve: CGFloat
    /// 搜索圆钮离右缘的距离
    let edgeTrailing: CGFloat
    let topPadding: CGFloat
    /// 外屏紧凑排法：搜索单独浮在前摄旁
    let floatingSearch: Bool

    init(safe: EdgeInsets, compact: Bool, fullBleed: Bool, sidePanelOpen: Bool, immersive: Bool = true) {
        self.immersive = immersive
        let centered = immersive && (!compact || safe.trailing >= 80)
        // 侧边评论栏打开时仍按视频区居中
        let hingeCentered = centered && fullBleed && !sidePanelOpen
        // statusRow：搜索停在右上角时间 / 电量那一组的左边（那一组实测占右侧约 122pt）
        let statusRow = centered && !compact && safe.top >= 60 && safe.trailing < 80
        self.centered = centered
        self.hingeCentered = hingeCentered
        self.statusRow = statusRow
        railReserve = immersive && !hingeCentered ? max(compact ? 70 : 78, safe.trailing) : 0
        edgeTrailing = statusRow ? 144 : (hingeCentered ? max(78, safe.trailing) + 12 : 12)
        // 外屏：状态栏在右侧系统条里，顶栏直接贴到顶部安全区。
        // 内屏竖放：和状态栏同一行——那一组中线距顶约 48pt（安全区 82pt），48pt 高的顶栏按同一条中线放。
        topPadding = statusRow ? safe.top / 2 - 17
            : max(safe.top, immersive && safe.trailing >= 80 ? 4 : (compact ? 44 : 16)) + 8
        floatingSearch = compact && !(immersive && safe.trailing >= 80)
    }
}

// MARK: - 量测

struct DYFoldedRecommendBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// 未取得系统遮挡边界时使用的保守设备布局参数，不是摄像头实测轮廓。
/// 如增加外屏设备型号，应按该型号校准这组预留值，而不是从 safeAreaInsets 推算镜头形状。
struct DYFoldedNavigationProfile {
    var cameraReservedWidth: CGFloat = 56
    var cameraReservedHeight: CGFloat = 64
    var cameraTrailingMargin: CGFloat = 16
    var cameraGap: CGFloat = 20
    var edgeMargin: CGFloat = 8
    var buttonSide: CGFloat = 44

    func fallbackCamera(in size: CGSize, safe: EdgeInsets) -> CGRect {
        CGRect(x: max(0, size.width - max(cameraTrailingMargin, safe.trailing) - cameraReservedWidth),
               y: 0, width: cameraReservedWidth, height: max(cameraReservedHeight, safe.top))
    }

    func searchFrame(size: CGSize, safe: EdgeInsets, camera: CGRect, recommend: CGRect) -> CGRect? {
        let left = max(edgeMargin, safe.leading)
        let right = size.width - max(edgeMargin, safe.trailing)
        let top = max(safe.top, 44) + edgeMargin
        let bottom = size.height - max(edgeMargin, safe.bottom)
        guard right - left >= buttonSide, bottom - top >= buttonSide else { return nil }
        let tabs = CGRect(x: left, y: recommend.minY,
                          width: max(0, recommend.maxX - left), height: recommend.height)
        // 优先与右上摄像头组合；只放在确实容得下完整点击区域的一侧。
        // 垂直方向跟顶栏 Tab 同一行（中心对齐「推荐」），不再按摄像头中心定位——那样会比顶栏低一截。
        let rowY = recommend.midY - buttonSide / 2
        for x in [camera.minX - cameraGap - buttonSide, camera.maxX + cameraGap] {
            let frame = CGRect(x: x, y: rowY, width: buttonSide, height: buttonSide)
            if frame.minX >= left, frame.maxX <= right, frame.maxY <= bottom,
               !frame.intersects(tabs.insetBy(dx: -edgeMargin, dy: 0)),
               !frame.intersects(camera) { return frame }
        }
        // 同行与 Tab 冲突时只移动搜索按钮：下一行仍优先保持摄像头旁的 20pt 水平间隔。
        let sideX = [camera.minX - cameraGap - buttonSide, camera.maxX + cameraGap]
            .first { $0 >= left && $0 + buttonSide <= right }
        // 极窄窗口两侧均放不下时，退到摄像头下方的右侧安全区。
        let frame = CGRect(x: sideX ?? (right - buttonSide),
                           y: max(top, camera.maxY + edgeMargin, recommend.maxY + edgeMargin),
                           width: buttonSide, height: buttonSide)
        return frame.maxY <= bottom ? frame : nil
    }
}


/// 顶栏在 `douduo.feed` 坐标里的框：直播页用它把「发现更多 / 正在直播」放到顶栏下面（随上游直播引入）。
struct DYTopChromeFrameKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.maxY > value.maxY { value = next }
    }
}

// MARK: - 顶栏

/// 已经摆好位置的顶栏：自带顶部渐变，并把自己的框报给 DYTopChromeFrameKey（直播页据此把按钮放到它下面）。
struct DYNavBar: View {
    let model: DYNavBarModel
    let placement: DYNavBarPlacement
    /// 画面铺满、控件压在画面上（内屏，或通透布局）：玻璃用通透款，「推荐」钉在正中
    let inner: Bool
    /// 侧边评论栏打开时顶栏只占视频那一块
    var width: CGFloat? = nil
    /// 左排排法躲前摄的右侧让位
    var topNudge: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        bar
            .padding(.top, placement.topPadding)
            .frame(width: width.map { max(0, $0 - placement.railReserve) })
            .padding(.trailing, placement.railReserve)
            .background {
                GeometryReader { bar in
                    LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.22), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: bar.size.height + 36)
                        .allowsHitTesting(false)
                        .preference(key: DYTopChromeFrameKey.self, value: bar.frame(in: .named("douduo.feed")))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 外屏独立使用紧凑导航；内屏保持原样：关注/推荐/直播、消息、头像、搜索 紧凑排成一组。
    /// 两种布局都在状态栏下方，并为右侧前摄预留空间。
    private var bar: some View {
        let centered = placement.centered
        return Group {
            if centered {
                centeredTopBar(pinRecommend: inner, edgeLeading: hSize != .compact ? 20 : 12, edgeTrailing: placement.edgeTrailing)
            } else if hSize == .compact || (placement.immersive) {
                compactTopBar
            } else {
                ViewThatFits(in: .horizontal) {
                    topBarRow(spacing: topNudge > 0 ? 5 : 14, hPad: 16)
                    topBarRow(spacing: 0, hPad: 10)
                    topBarRow(spacing: 0, hPad: 5)
                }
            }
        }
        .themeShadow(.mediaLabel)
        .frame(maxWidth: .infinity, minHeight: 48)
        // 居中顶栏不躲前摄：两侧内容离屏幕右上角很远，偏移只会把「推荐」带离中线
        .padding(.trailing, centered ? 0 : topNudge)
    }

    /// 外屏按内容宽度从左排列。44pt 点击区已贡献文字两侧留白，
    /// 再加 6pt 统一间距，常规字号下文字的可见间距约 16pt。
    private var compactTopBar: some View {
        ViewThatFits(in: .horizontal) {
            compactTopBarRow(spacing: 6)
                .fixedSize(horizontal: true, vertical: false)
            compactTopBarRow(spacing: 2)
                .fixedSize(horizontal: true, vertical: false)
            // 极窄窗口保留全部入口，横向滚动而不压缩、重叠文字。
            ScrollView(.horizontal) {
                compactTopBarRow(spacing: 2)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    /// B（外屏 / 内屏）：直播、搜索是两端的玻璃圆钮，中间一组文字 Tab。
    /// pinRecommend（内屏）：两侧等宽弹性占位，「推荐」钉在折痕上；
    /// 否则（外屏）四个 Tab 整组居中，整条顶栏左右对称。
    private func centeredTopBar(pinRecommend: Bool, edgeLeading: CGFloat, edgeTrailing: CGFloat) -> some View {
        ZStack {
            HStack(alignment: .center, spacing: 6) {
                HStack(spacing: 6) {
                    compactEntry("我的", selected: false, id: "douyin.mine.top") { model.openMine() }
                    compactEntry(DYTab.follow.title, selected: model.tab == .follow, id: "douyin.tab.follow") { model.select(.follow) }
                }
                .frame(maxWidth: pinRecommend ? .infinity : nil, alignment: .trailing)
                compactRecommendEntry
                compactEntry("消息", selected: false, dot: model.noticeUnread > 0, id: "douyin.messages.top") { model.openMessages() }
                    .frame(maxWidth: pinRecommend ? .infinity : nil, alignment: .leading)
            }
            HStack(spacing: 0) {
                compactLiveButton(inGlass: true).ddGlassCapsule(clear: pinRecommend)
                Spacer(minLength: 0)
                compactSearchButton.ddGlassCapsule(clear: pinRecommend)
            }
            .padding(.leading, edgeLeading)
            .padding(.trailing, edgeTrailing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var compactSearchButton: some View {
        Button { model.openSearch() } label: {
            Image(systemName: "magnifyingglass")
                .resizable().scaledToFit()
                .fontWeight(.semibold)
                .frame(width: 20, height: 20)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("搜索").accessibilityIdentifier("douyin.search")
    }

    /// inGlass：玻璃圆钮里的图标缩到和搜索图标（20pt）视觉等大
    private func compactLiveButton(inGlass: Bool = false) -> some View {
        Button { model.select(.live) } label: {
            Image(systemName: "play.tv")
                .resizable().scaledToFit()
                .frame(width: inGlass ? 23 : 32, height: inGlass ? 18 : 24)
                .foregroundStyle(.white.opacity(model.tab == .live ? 1 : 0.9))
                .frame(width: 44, height: 44)
                .overlay(alignment: .bottom) {
                    Capsule().fill(.white).frame(width: 18, height: 2.5)
                        .opacity(model.tab == .live ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel("直播").accessibilityIdentifier("douyin.tab.live")
    }

    private var compactRecommendEntry: some View {
        compactEntry(DYTab.recommend.title, selected: model.tab == .recommend, loading: model.refreshing, id: "douyin.tab.recommend") {
            model.select(.recommend)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.refreshRecommend()
        })
    }

    private func compactTopBarRow(spacing: CGFloat) -> some View {
        HStack(alignment: .center, spacing: spacing) {
            compactLiveButton()

            compactEntry("我的", selected: false, id: "douyin.mine.top") { model.openMine() }
            compactEntry("消息", selected: false, dot: model.noticeUnread > 0, id: "douyin.messages.top") { model.openMessages() }
            compactEntry(DYTab.follow.title, selected: model.tab == .follow, id: "douyin.tab.follow") { model.select(.follow) }
            compactRecommendEntry
            .anchorPreference(key: DYFoldedRecommendBoundsKey.self, value: .bounds) { $0 }

            // 仅保留旧按钮的布局占位，保证 ViewThatFits 的间距选择和所有 Tab 位置不变。
            if placement.immersive && hSize != .compact {
                Button { model.openSearch() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("搜索").accessibilityIdentifier("douyin.search")
            } else {
                Color.clear.frame(width: 44, height: 44)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func compactEntry(_ title: String, selected: Bool, dot: Bool = false, loading: Bool = false,
                              id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: selected ? .bold : .semibold))
                .lineLimit(1).fixedSize()
                .opacity(loading ? 0 : 1)
                .overlay { if loading { ProgressView().tint(.white) } }
                .overlay(alignment: .topTrailing) {
                    if dot { Circle().fill(.red).frame(width: 7, height: 7).offset(x: 6, y: -2) }
                }
                .foregroundStyle(.white.opacity(selected ? 1 : 0.72))
                .frame(minWidth: 44, minHeight: 44)
                .overlay(alignment: .bottom) {
                    Capsule().fill(.white).frame(width: 22, height: 2.5).opacity(selected ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func topBarRow(spacing: CGFloat, hPad: CGFloat) -> some View {
        // 触摸区左右各扩 hPad、上下各扩 14（图标与字号不动）
        HStack(spacing: spacing) {
            ForEach(DYTab.allCases, id: \.self) { t in
                Button { model.select(t) } label: {
                    VStack(spacing: 3) {
                        Text(t.title)
                            .font(.headline.weight(model.tab == t ? .bold : .medium))
                            .foregroundStyle(theme.media.onMedia.color(for: scheme).opacity(model.tab == t ? 1 : 0.62))
                            .lineLimit(1).fixedSize()
                            .opacity(t == .recommend && model.refreshing ? 0 : 1)
                            .overlay {
                                if t == .recommend && model.refreshing {
                                    ProgressView().tint(theme.media.onMedia.color(for: scheme))
                                        .accessibilityLabel("正在刷新推荐")
                                }
                            }
                        Capsule()
                            .fill(theme.media.onMedia.color(for: scheme))
                            .frame(width: 16, height: 3)
                            .opacity(model.tab == t ? 1 : 0)
                    }
                    // 文字本身小，撑开触摸区，避免点不中/误判成下拉
                    .padding(.horizontal, hPad)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    guard t == .recommend else { return }
                    model.refreshRecommend()
                })
            }
            // 消息只留图标，未读红点仍独立显示。
            Button { model.openMessages() } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(theme.media.onMedia.color(for: scheme).opacity(0.62))
                .padding(.horizontal, hPad)
                .padding(.vertical, 14)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if model.noticeUnread > 0 {
                        Circle().fill(theme.status.danger.color(for: scheme))
                            .frame(width: 7, height: 7)
                            .offset(x: -(hPad - 2), y: 10)
                            .allowsHitTesting(false)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("消息")
            .accessibilityIdentifier("douyin.messages.top")

            // 「我的」：独立按钮（不属于 tab 切换）
            Button { model.openMine() } label: {
                HStack(spacing: 5) {
                    CachedAsyncImage(url: model.avatar) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 19))
                            .foregroundStyle(theme.media.onMedia.color(for: scheme).opacity(0.62))
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                }
                .padding(.horizontal, max(hPad - 2, 4))
                .padding(.vertical, 12)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("我的")
            .accessibilityIdentifier("douyin.mine.top")
            Button { model.openSearch() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(theme.media.onMedia.color(for: scheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索")
            .accessibilityIdentifier("douyin.search")
        }
        .fixedSize()
    }
}

// MARK: - 外屏浮动搜索

/// 外屏紧凑排法下的搜索按钮：跟顶栏 Tab 同一行，放在前摄旁容得下完整点击区的一侧。
struct DYNavBarFloatingSearch: View {
    let geo: GeometryProxy
    let safeInsets: EdgeInsets
    let recommend: CGRect
    let action: () -> Void

    var body: some View {
        let profile = DYFoldedNavigationProfile()
        let safe = EdgeInsets(top: max(safeInsets.top, geo.safeAreaInsets.top),
                              leading: max(safeInsets.leading, geo.safeAreaInsets.leading),
                              bottom: max(safeInsets.bottom, geo.safeAreaInsets.bottom),
                              trailing: max(safeInsets.trailing, geo.safeAreaInsets.trailing))
        let camera = foldedCameraRegion(in: geo) ?? profile.fallbackCamera(in: geo.size, safe: safe)
        let frame = profile.searchFrame(size: geo.size, safe: safe, camera: camera, recommend: recommend)
        return Group {
            if let frame {
                Button(action: action) {
                    Image(systemName: "magnifyingglass")
                        .resizable().scaledToFit()
                        // 跟顶栏 17pt 文字视觉等高；点击区仍是 44pt
                        .fontWeight(.semibold)
                        .frame(width: 20, height: 20)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .themeShadow(.mediaLabel)
                .accessibilityLabel("搜索").accessibilityIdentifier("douyin.search")
                .position(x: frame.midX, y: frame.midY)
            }
        }
    }

    private func foldedCameraRegion(in geo: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        var camera: CGRect?
        for region in geo.reservedRegions(kind: .occlusion) where region.isActive {
            let frame = region.frame
            guard frame.width > 1, frame.height > 1,
                  frame.minY < 140, frame.minX > geo.size.width * 0.5 else { continue }
            camera = camera.map { $0.union(frame) } ?? frame
        }
        return camera
    }
}
