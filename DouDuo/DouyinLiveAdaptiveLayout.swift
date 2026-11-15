import CoreGraphics

/// 直播自适应布局的纯计算。不读设备、不发请求、不碰播放器。
/// 系统只提供折痕开合，没有桌面/书本轴向；轴向由 division 矩形推断，真机几何尚未核对。
enum DYLiveHingeStatus: Equatable {
    case unsupported
    case closed
    case partiallyOpen
    case fullyOpen
}

struct DYLiveDivision: Equatable {
    var frame: CGRect
    var isActive: Bool
}

enum DYLiveStreamOrientation: Equatable {
    case unknown
    case portrait
    case landscape
}

enum DYLiveAdaptiveLayout: Equatable {
    /// 整屏。画面和交互层都铺满可用区域。
    case existing
    /// 桌面半折叠且流是横屏：上画面，下交互，中间让出折痕。
    case layoutA
    /// 书本半折叠：左画面，右交互，中间让出折痕。方向未知也走这里。
    case layoutB
}

struct DYLiveAdaptiveDecision: Equatable {
    var layout: DYLiveAdaptiveLayout
    var video: CGRect
    var interaction: CGRect
}

/// 上一帧已经采纳的分屏。折痕几何短暂丢失时用来保住矩形，避免来回跳。
struct DYLiveAdaptiveMemory: Equatable {
    var decision: DYLiveAdaptiveDecision
    var bounds: CGRect

    static let empty = DYLiveAdaptiveMemory(
        decision: DYLiveAdaptiveDecision(layout: .existing, video: .zero, interaction: .zero),
        bounds: .zero)
}

enum DYLiveAdaptiveLayoutEngine {
    /// 宽高比达到这个倍数才算横屏或竖屏。4:3 是 1.333；1:1 和轻微偏差留在未知。
    static let orientationRatio: CGFloat = 1.2
    /// 折痕带的长边至少是短边的这么多倍。
    static let hingeAspect: CGFloat = 2
    /// 折痕带要盖住所在轴向的大部分。
    static let hingeSpan: CGFloat = 0.6
    /// 折痕带不能厚到占掉该轴向的大半。
    static let hingeThickness: CGFloat = 0.4
    /// 分屏后每一侧至少占该轴向的这个比例，否则退回整屏。
    static let minimumPane: CGFloat = 0.2

    static func orientation(videoSize: CGSize?) -> DYLiveStreamOrientation {
        guard let videoSize else { return .unknown }
        let width = videoSize.width
        let height = videoSize.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return .unknown }
        if width >= height * orientationRatio { return .landscape }
        if height >= width * orientationRatio { return .portrait }
        return .unknown
    }

    static func decide(
        bounds: CGRect,
        status: DYLiveHingeStatus,
        divisions: [DYLiveDivision],
        videoSize: CGSize?
    ) -> DYLiveAdaptiveDecision {
        let bounds = bounds.standardized
        guard usable(bounds) else {
            return DYLiveAdaptiveDecision(layout: .existing, video: .zero, interaction: .zero)
        }
        let full = DYLiveAdaptiveDecision(layout: .existing, video: bounds, interaction: bounds)
        guard status == .partiallyOpen, let band = hingeBand(in: bounds, divisions: divisions) else {
            return full
        }
        switch band.axis {
        case .tabletop:
            guard orientation(videoSize: videoSize) == .landscape,
                  let panes = split(bounds, band: band.frame, axis: .tabletop) else { return full }
            return DYLiveAdaptiveDecision(layout: .layoutA, video: panes.video, interaction: panes.interaction)
        case .book:
            guard let panes = split(bounds, band: band.frame, axis: .book) else { return full }
            return DYLiveAdaptiveDecision(layout: .layoutB, video: panes.video, interaction: panes.interaction)
        }
    }

    /// 展开状态下手动分屏（没有折痕）。横屏画面 + 竖向屏幕：上画面下交互；其余左画面右交互。
    /// 画面窗格按画面比例取大小并夹在 35%–65% 之间，交互区至少留 35%。
    static func manualSplit(bounds: CGRect, videoSize: CGSize?) -> DYLiveAdaptiveDecision {
        let bounds = bounds.standardized
        let full = DYLiveAdaptiveDecision(layout: .existing, video: bounds, interaction: bounds)
        guard usable(bounds) else { return full }
        let aspect: CGFloat = {
            guard let v = videoSize, v.width.isFinite, v.height.isFinite, v.width > 1, v.height > 1 else { return 0 }
            return v.width / v.height
        }()
        if orientation(videoSize: videoSize) == .landscape, bounds.height >= bounds.width {
            let wanted = bounds.width / aspect + 56
            let h = min(max(wanted, bounds.height * 0.35), bounds.height * 0.65)
            return DYLiveAdaptiveDecision(
                layout: .layoutA,
                video: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: h),
                interaction: CGRect(x: bounds.minX, y: bounds.minY + h, width: bounds.width, height: bounds.height - h))
        }
        let wanted = aspect > 0 ? bounds.height * aspect : bounds.width * 0.55
        let w = min(max(wanted, bounds.width * 0.35), bounds.width * 0.65)
        return DYLiveAdaptiveDecision(
            layout: .layoutB,
            video: CGRect(x: bounds.minX, y: bounds.minY, width: w, height: bounds.height),
            interaction: CGRect(x: bounds.minX + w, y: bounds.minY, width: bounds.width - w, height: bounds.height))
    }

    /// 半折叠时只按折痕切成两块，不看画面方向。推荐流的视频/评论分屏复用这套几何，和直播 Layout A/B 同一条折痕。
    /// 书本：first 在左、second 在右；桌面：first 在上、second 在下。中间的折痕带两边都不占。
    static func hingePanes(bounds: CGRect, divisions: [DYLiveDivision]) -> (first: CGRect, second: CGRect, book: Bool)? {
        let bounds = bounds.standardized
        guard usable(bounds), let band = hingeBand(in: bounds, divisions: divisions),
              let panes = split(bounds, band: band.frame, axis: band.axis) else { return nil }
        return (panes.video, panes.interaction, band.axis == .book)
    }

    /// 房间还没出画，或尺寸非法时返回 nil。调用方据此保持未知方向，不用上一间的尺寸。
    static func presentationSize(ready: Bool, videoSize: CGSize) -> CGSize? {
        guard ready else { return nil }
        guard videoSize.width.isFinite, videoSize.height.isFinite, videoSize.width > 0, videoSize.height > 0 else { return nil }
        return videoSize
    }

    /// 解码尺寸经常在 `.playing` 之后才变成非零。同一尺寸不重复发布；换房间后的旧回调直接丢掉。
    static func acceptedSize(
        current: CGSize,
        sample: CGSize,
        generation: Int,
        callbackGeneration: Int,
        playerIsCurrent: Bool
    ) -> CGSize? {
        guard playerIsCurrent, generation == callbackGeneration else { return nil }
        guard sample.width.isFinite, sample.height.isFinite, sample.width > 1, sample.height > 1 else { return nil }
        guard sample != current else { return nil }
        return sample
    }

    /// 半折叠但折痕带暂时无法分类。方向变化不算瞬时丢失。
    static func hingeIsTransient(bounds: CGRect, status: DYLiveHingeStatus, divisions: [DYLiveDivision]) -> Bool {
        status == .partiallyOpen && hingeBand(in: bounds.standardized, divisions: divisions) == nil
    }

    /// 只在同一边界里、折痕带短暂消失时保留上一次分屏。展开、合上、换方向都立刻采纳新结果。
    static func stabilize(
        previous: DYLiveAdaptiveMemory,
        proposed: DYLiveAdaptiveDecision,
        status: DYLiveHingeStatus,
        bounds: CGRect,
        divisions: [DYLiveDivision]
    ) -> DYLiveAdaptiveMemory {
        let bounds = bounds.standardized
        let hold = hingeIsTransient(bounds: bounds, status: status, divisions: divisions)
            && previous.decision.layout != .existing
            && previous.bounds.standardized == bounds
        if hold { return previous }
        return DYLiveAdaptiveMemory(decision: proposed, bounds: bounds)
    }

    private enum Axis {
        case tabletop
        case book
    }

    private struct Band {
        var axis: Axis
        var frame: CGRect
    }

    private static func usable(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite && bounds.origin.y.isFinite
            && bounds.width.isFinite && bounds.height.isFinite
            && bounds.width > 0 && bounds.height > 0
    }

    private static func hingeBand(in bounds: CGRect, divisions: [DYLiveDivision]) -> Band? {
        let active = divisions.filter { region in
            let frame = region.frame.standardized
            return region.isActive
                && frame.origin.x.isFinite && frame.origin.y.isFinite
                && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
        }
        guard active.count == 1 else { return nil }
        let clipped = active[0].frame.standardized.intersection(bounds)
        guard clipped.width > 0, clipped.height > 0 else { return nil }
        if clipped.width >= clipped.height * hingeAspect,
           clipped.width >= bounds.width * hingeSpan,
           clipped.height <= bounds.height * hingeThickness {
            return Band(axis: .tabletop, frame: clipped)
        }
        if clipped.height >= clipped.width * hingeAspect,
           clipped.height >= bounds.height * hingeSpan,
           clipped.width <= bounds.width * hingeThickness {
            return Band(axis: .book, frame: clipped)
        }
        return nil
    }

    private static func split(_ bounds: CGRect, band: CGRect, axis: Axis) -> (video: CGRect, interaction: CGRect)? {
        switch axis {
        case .tabletop:
            let video = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: band.minY - bounds.minY)
            let interaction = CGRect(x: bounds.minX, y: band.maxY, width: bounds.width, height: bounds.maxY - band.maxY)
            guard pane(video.height, of: bounds.height), pane(interaction.height, of: bounds.height) else { return nil }
            return (video, interaction)
        case .book:
            let video = CGRect(x: bounds.minX, y: bounds.minY, width: band.minX - bounds.minX, height: bounds.height)
            let interaction = CGRect(x: band.maxX, y: bounds.minY, width: bounds.maxX - band.maxX, height: bounds.height)
            guard pane(video.width, of: bounds.width), pane(interaction.width, of: bounds.width) else { return nil }
            return (video, interaction)
        }
    }

    private static func pane(_ length: CGFloat, of total: CGFloat) -> Bool {
        length.isFinite && length > 0 && length >= total * minimumPane
    }
}

/// Layout A 上窗格里的横屏画面。安全区来自调用方，这里只负责在窗格内底对齐。
enum DYLiveLayoutAVideo {
    /// 状态栏下沿再留的空隙。不是某台设备的状态栏高度。
    static let statusMargin: CGFloat = 8

    static func aspect(of size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return 0 }
        return size.width / size.height
    }

    /// 尺寸未知时占住状态栏以下的整个窗格，避免画面先画进状态栏。
    /// 尺寸已知时取能放下的最大完整矩形，横向居中，底边贴住窗格下沿。
    static func frame(in pane: CGRect, aspect: CGFloat, safeTop: CGFloat) -> CGRect {
        let pane = pane.standardized
        guard pane.width > 1, pane.height > 1, pane.minX.isFinite, pane.minY.isFinite else { return .zero }
        let reportedTop = safeTop.isFinite && safeTop > 0.5 ? safeTop : 0
        let ceiling = reportedTop > 0 ? reportedTop + statusMargin : pane.minY
        let top = min(pane.maxY - 1, max(pane.minY, ceiling))
        let usable = CGRect(x: pane.minX, y: top, width: pane.width, height: pane.maxY - top)
        guard aspect.isFinite, aspect > 0 else { return usable }
        let fullWidthHeight = usable.width / aspect
        if fullWidthHeight <= usable.height {
            return CGRect(x: usable.minX, y: usable.maxY - fullWidthHeight, width: usable.width, height: fullWidthHeight)
        }
        let width = usable.height * aspect
        return CGRect(x: usable.midX - width / 2, y: usable.minY, width: width, height: usable.height)
    }
}
