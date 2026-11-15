import SwiftUI

/// 直播交互区的环境光背景。画面本身仍由现有播放器绘制。
/// Layout A 的交互区在画面下方，光从折痕（上沿）向下淡出。
/// Layout B 的交互区在画面右方，光从折痕（左沿）向右淡出。
/// 封面只用来取色。画面上的轮廓不再放大铺开，避免低分辨率色块和斜向分界。
/// 模糊在封面变化时做一次，不在 body 里重算。
struct DouyinLiveAmbientBackground: View {
    /// 已有房间封面。没有缓存时才经 ImageCache 取缩略图。
    var coverURL: URL?
    var axis: DYLiveAmbientAxis
    /// 账号或会话代际。换账号后旧任务即使拿到同一张封面，也不能写回当前画面。
    var isolationID: String = ""
    /// 预览和测试直接给图。有图时不再读取 coverURL，也不会发起加载。
    var artwork: UIImage?

    @State private var displayedKey = ""
    @State private var palette = DYLiveAmbientPalette.neutral

    var body: some View {
        // MARK: - ambient-body
        let fade = DYLiveAmbientTreatment.fade(for: axis)
        ZStack {
            treatmentColor(DYLiveAmbientTreatment.fallback)
            if displayedKey == sourceToken, palette != DYLiveAmbientPalette.neutral {
                glowField(palette, fade: fade)
                    .id(displayedKey)
                    .transition(.opacity)
            }
            maskGradient(DYLiveAmbientTreatment.plateStops, fade: fade, color: .black)
            maskGradient(DYLiveAmbientTreatment.veilStops, fade: fade, color: .black)
        }
        .animation(.easeInOut(duration: DYLiveAmbientTreatment.transitionDuration), value: displayedKey)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // MARK: - ambient-body-end
        .task(id: sourceToken) { await refreshArtwork() }
    }

    private var sourceToken: String {
        let artworkID: String
        if let artwork {
            artworkID = "artwork:\(ObjectIdentifier(artwork).hashValue)"
        } else if let coverURL {
            artworkID = "cover:\(coverURL.absoluteString)"
        } else {
            artworkID = "fallback"
        }
        return DYLiveAmbientIdentity.token(isolationID: isolationID, artwork: artworkID)
    }

    // MARK: - ambient-refresh
    private func refreshArtwork() async {
        let token = sourceToken
        let requestedCover = artwork == nil ? coverURL : nil
        let requestedArtwork = artwork
        guard !DYLiveAmbientIdentity.isFallback(token) else {
            publish(.neutral, token: token)
            return
        }
        if displayedKey == token, palette != .neutral { return }
        if let cached = DYLiveAmbientBlurStore.shared.peek(token) {
            publish(cached.palette, token: token)
            return
        }
        guard let source = await Self.sourceImage(coverURL: requestedCover, artwork: requestedArtwork) else {
            publish(.neutral, token: token)
            return
        }
        guard stillCurrent(token) else { return }
        guard let bitmap = DYLiveAmbientBitmap.scaled(from: source, maxPixel: DYLiveAmbientTreatment.sourceMaxPixel) else { return }
        let prepared = await Task.detached(priority: .utility) {
            DYLiveAmbientPrepared(palette: DYLiveAmbientPalette.extract(from: bitmap))
        }.value
        guard stillCurrent(token) else { return }
        let kept = DYLiveAmbientBlurStore.shared.resolve(key: token) { prepared }
        publish(kept.palette, token: token)
    }

    /// 只接受这次任务自己的房间和账号。过期或已取消的结果直接丢掉。
    private func publish(_ palette: DYLiveAmbientPalette, token: String) {
        guard stillCurrent(token) else { return }
        self.palette = palette
        displayedKey = token
    }

    private func stillCurrent(_ token: String) -> Bool {
        DYLiveAmbientIdentity.shouldApply(requested: token, current: sourceToken, cancelled: Task.isCancelled)
    }

    /// 内存里已有原图或缩略图就直接用。未命中时只走一次 `loadThumb`，
    /// 由 ImageCache 合并同一 URL 正在进行的下载，这里不再另开请求。
    private static func sourceImage(coverURL: URL?, artwork: UIImage?) async -> UIImage? {
        if let artwork { return artwork }
        guard let coverURL else { return nil }
        let maxPixel = DYLiveAmbientTreatment.sourceMaxPixel
        if let thumb = ImageCache.shared.memoryThumb(coverURL, maxPixel: maxPixel) { return thumb }
        if let cached = ImageCache.shared.memoryCached(coverURL) { return cached }
        return await ImageCache.shared.loadThumb(coverURL, maxPixel: maxPixel)
    }
    // MARK: - ambient-refresh-end

    /// 主色铺底、辅光和贴边溢光都沿窗格轴向渐变。椭圆半径伸出窗格，避免看见圆边。
    private func glowField(_ palette: DYLiveAmbientPalette, fade: DYLiveAmbientFade) -> some View {
        let ends = endpoints(fade)
        let primaryCenter: UnitPoint = axis == .vertical ? UnitPoint(x: 0.42, y: -0.08) : UnitPoint(x: -0.08, y: 0.42)
        let secondaryCenter: UnitPoint = axis == .vertical ? UnitPoint(x: 0.72, y: 0.42) : UnitPoint(x: 0.42, y: 0.72)
        return ZStack {
            LinearGradient(
                stops: colorStops(palette.primary, DYLiveAmbientTreatment.artworkStops, 1),
                startPoint: ends.start,
                endPoint: ends.end)
            LinearGradient(
                stops: colorStops(palette.primary, DYLiveAmbientTreatment.reflectionStops, DYLiveAmbientTreatment.reflectionOpacity),
                startPoint: ends.start,
                endPoint: ends.end)
            softGlow(palette.primary, center: primaryCenter, strength: DYLiveAmbientTreatment.primaryGlowStrength, radius: 1.65)
            softGlow(palette.secondary, center: secondaryCenter, strength: DYLiveAmbientTreatment.secondaryGlowStrength, radius: 1.85)
            LinearGradient(
                stops: colorStops(palette.primary, DYLiveAmbientTreatment.spillStops, DYLiveAmbientTreatment.spillStrength),
                startPoint: ends.start,
                endPoint: ends.end)
            maskGradient(DYLiveAmbientTreatment.brightnessScrimStops(palette.sourceLuminance), fade: fade, color: .black)
        }
        .allowsHitTesting(false)
    }

    private func softGlow(_ color: DYLiveAmbientRGB, center: UnitPoint, strength: CGFloat, radius: CGFloat) -> some View {
        EllipticalGradient(
            stops: [
                Gradient.Stop(color: treatmentColor(color).opacity(strength), location: 0),
                Gradient.Stop(color: treatmentColor(color).opacity(strength * 0.62), location: 0.28),
                Gradient.Stop(color: treatmentColor(color).opacity(strength * 0.24), location: 0.62),
                Gradient.Stop(color: treatmentColor(color).opacity(0), location: 1),
            ],
            center: center,
            startRadiusFraction: 0,
            endRadiusFraction: radius)
    }

    private func colorStops(_ color: DYLiveAmbientRGB, _ stops: [DYLiveAmbientStop], _ strength: CGFloat) -> [Gradient.Stop] {
        stops.map {
            Gradient.Stop(color: treatmentColor(color).opacity(Double($0.opacity * strength)), location: $0.location)
        }
    }

    private func maskGradient(_ stops: [DYLiveAmbientStop], fade: DYLiveAmbientFade, color: Color) -> LinearGradient {
        let ends = endpoints(fade)
        return LinearGradient(
            stops: stops.map {
                Gradient.Stop(color: color.opacity(Double($0.opacity)), location: $0.location)
            },
            startPoint: ends.start,
            endPoint: ends.end)
    }

    private func endpoints(_ fade: DYLiveAmbientFade) -> (start: UnitPoint, end: UnitPoint) {
        (point(fade.start), point(fade.end))
    }

    private func point(_ edge: DYLiveAmbientEdge) -> UnitPoint {
        switch edge {
        case .minY: return .top
        case .maxY: return .bottom
        case .minX: return UnitPoint(x: 0, y: 0.5)
        case .maxX: return UnitPoint(x: 1, y: 0.5)
        }
    }

    private func treatmentColor(_ color: DYLiveAmbientRGB) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue)
    }
}

// MARK: - ambient-treatment

enum DYLiveAmbientIdentity {
    private static let separator = "\u{1e}"

    static func token(isolationID: String, artwork: String) -> String {
        isolationID + separator + artwork
    }

    static func isFallback(_ token: String) -> Bool {
        token.hasSuffix(separator + "fallback")
    }

    /// 请求发出时的身份必须仍是当前身份，任务也没有取消。
    static func shouldApply(requested: String, current: String, cancelled: Bool) -> Bool {
        !cancelled && requested == current
    }
}

enum DYLiveAmbientAxis: Equatable {
    /// Layout A：交互区在下，沿垂直方向从折痕淡出。
    case vertical
    /// Layout B：交互区在右，沿水平方向从折痕淡出。
    case horizontal
}

enum DYLiveAmbientEdge: Equatable {
    case minX
    case maxX
    case minY
    case maxY
}

struct DYLiveAmbientFade: Equatable {
    var start: DYLiveAmbientEdge
    var end: DYLiveAmbientEdge
}

struct DYLiveAmbientStop: Equatable {
    var location: CGFloat
    var opacity: CGFloat
}

struct DYLiveAmbientRGB: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
}

enum DYLiveAmbientTreatment {
    /// 模糊源的长边上限。环境光不需要封面细节。
    static let sourceMaxPixel = 72
    /// 房间切换时的交叉淡入，只播一次。
    static let transitionDuration: Double = 0.45
    /// 交互区中段的压暗。折痕更轻，评论侧更重，不再整块用同一个黑色。
    static let plateOpacity: CGFloat = 0.52
    /// 折痕一侧的低分辨率倒影。主溢光另算，倒影只留一层薄的。
    static let reflectionOpacity: CGFloat = 0.32
    static let primaryGlowStrength: CGFloat = 0.42
    static let secondaryGlowStrength: CGFloat = 0.2
    static let spillStrength: CGFloat = 0.4
    static let minimumTextContrast: CGFloat = 4.5
    static let fallback = DYLiveAmbientRGB(red: 0.067, green: 0.067, blue: 0.074)

    /// 0 是贴着画面的折痕，1 是交互区外侧。折痕一侧留更多封面色。
    static let artworkStops: [DYLiveAmbientStop] = [
        DYLiveAmbientStop(location: 0, opacity: 0.88),
        DYLiveAmbientStop(location: 0.42, opacity: 0.52),
        DYLiveAmbientStop(location: 1, opacity: 0.16),
    ]
    static let reflectionStops: [DYLiveAmbientStop] = [
        DYLiveAmbientStop(location: 0, opacity: 0.95),
        DYLiveAmbientStop(location: 0.48, opacity: 0.12),
        DYLiveAmbientStop(location: 1, opacity: 0),
    ]
    static let veilStops: [DYLiveAmbientStop] = [
        DYLiveAmbientStop(location: 0, opacity: 0.02),
        DYLiveAmbientStop(location: 1, opacity: 0.4),
    ]
    /// 0 贴着画面。主光从折痕铺开，辅光在中段，溢光只留在贴边。
    static let primaryGlowStops: [DYLiveAmbientStop] = [
        DYLiveAmbientStop(location: 0, opacity: 0.9),
        DYLiveAmbientStop(location: 0.5, opacity: 0.28),
        DYLiveAmbientStop(location: 1, opacity: 0.06),
    ]
    static let secondaryGlowStops: [DYLiveAmbientStop] = [
        DYLiveAmbientStop(location: 0, opacity: 0.12),
        DYLiveAmbientStop(location: 0.42, opacity: 0.85),
        DYLiveAmbientStop(location: 1, opacity: 0.08),
    ]
    static let spillStops: [DYLiveAmbientStop] = [
        DYLiveAmbientStop(location: 0, opacity: 1),
        DYLiveAmbientStop(location: 0.18, opacity: 0.72),
        DYLiveAmbientStop(location: 0.4, opacity: 0.38),
        DYLiveAmbientStop(location: 0.68, opacity: 0.12),
        DYLiveAmbientStop(location: 1, opacity: 0),
    ]
    static var plateStops: [DYLiveAmbientStop] {
        [
            DYLiveAmbientStop(location: 0, opacity: 0.3),
            DYLiveAmbientStop(location: 0.5, opacity: plateOpacity),
            DYLiveAmbientStop(location: 1, opacity: 0.66),
        ]
    }

    static func brightnessScrimStops(_ luminance: CGFloat) -> [DYLiveAmbientStop] {
        let bright = min(1, max(0, (luminance - 0.12) / 0.55))
        return [
            DYLiveAmbientStop(location: 0, opacity: 0.02 + bright * 0.06),
            DYLiveAmbientStop(location: 1, opacity: 0.08 + bright * 0.3),
        ]
    }

    static func axis(for layout: DYLiveAdaptiveLayout) -> DYLiveAmbientAxis? {
        switch layout {
        case .layoutA: return .vertical
        case .layoutB: return .horizontal
        case .existing: return nil
        }
    }

    static func fade(for axis: DYLiveAmbientAxis) -> DYLiveAmbientFade {
        switch axis {
        case .vertical:
            return DYLiveAmbientFade(start: .minY, end: .maxY)
        case .horizontal:
            return DYLiveAmbientFade(start: .minX, end: .maxX)
        }
    }

    static func artworkOpacity(at location: CGFloat) -> CGFloat {
        opacity(at: location, stops: artworkStops)
    }

    static func backdrop(artwork: DYLiveAmbientRGB?, location: CGFloat) -> DYLiveAmbientRGB {
        guard let artwork else { return composited(nil, location: location) }
        return composited(DYLiveAmbientPalette.make(average: artwork, accent: artwork), location: location)
    }

    /// 用已经定好的主色和辅色合成背景。纯色样本和分桶取色走同一条压暗。
    static func composited(_ palette: DYLiveAmbientPalette?, location: CGFloat) -> DYLiveAmbientRGB {
        let black = DYLiveAmbientRGB(red: 0, green: 0, blue: 0)
        var pixel = fallback
        if let palette {
            pixel = over(pixel, palette.primary, opacity: artworkOpacity(at: location))
            let reflection = opacity(at: location, stops: reflectionStops) * reflectionOpacity
            pixel = over(pixel, palette.primary, opacity: reflection)
            pixel = over(pixel, palette.primary, opacity: opacity(at: location, stops: primaryGlowStops) * primaryGlowStrength)
            pixel = over(pixel, palette.secondary, opacity: opacity(at: location, stops: secondaryGlowStops) * secondaryGlowStrength)
            pixel = over(pixel, palette.primary, opacity: opacity(at: location, stops: spillStops) * spillStrength)
            pixel = over(pixel, black, opacity: opacity(at: location, stops: brightnessScrimStops(palette.sourceLuminance)))
        }
        pixel = over(pixel, black, opacity: opacity(at: location, stops: plateStops))
        pixel = over(pixel, black, opacity: opacity(at: location, stops: veilStops))
        return pixel
    }

    /// 亮色压暗、暗色抬起、高饱和收一点。辅色只降低明度，不再另转色相。
    static func graded(_ color: DYLiveAmbientRGB, accent: Bool = false) -> DYLiveAmbientRGB {
        let (h, s, v) = hsv(color)
        let neutral = neutralGrade(v, accent: accent)
        let chromatic = chromaticGrade(h: h, s: s, v: v, accent: accent)
        return mix(neutral, chromatic, smoothstep(0.06, 0.16, s))
    }

    static func neutralGrade(_ v: CGFloat, accent: Bool) -> DYLiveAmbientRGB {
        let cap: CGFloat = accent ? 0.12 : 0.24
        let lifted: CGFloat = v < 0.05 ? 0.06 : min(cap, 0.08 + v * 0.22)
        return DYLiveAmbientRGB(red: lifted, green: lifted, blue: min(1, lifted + (accent ? 0.02 : 0.012)))
    }

    static func chromaticGrade(h: CGFloat, s: CGFloat, v: CGFloat, accent: Bool) -> DYLiveAmbientRGB {
        var saturation = s
        var value = v
        if saturation > 0.75 { saturation = 0.75 + (saturation - 0.75) * 0.2 }
        if value < 0.16 {
            value = 0.16 + (0.16 - value) * 0.8
        } else if value > 0.48 {
            value = 0.48 - (value - 0.48) * 0.45
        }
        if accent {
            saturation *= 0.75
            value *= 0.7
        }
        return rgb(h: h, s: min(0.68, saturation), v: min(accent ? 0.3 : 0.46, value))
    }

    static func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let delta = abs(a - b)
        return min(delta, 1 - delta)
    }

    static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        let span = edge1 - edge0
        let t = span > 0 ? min(1, max(0, (value - edge0) / span)) : (value < edge0 ? 0 : 1)
        return t * t * (3 - 2 * t)
    }

    static func mix(_ a: DYLiveAmbientRGB, _ b: DYLiveAmbientRGB, _ amount: CGFloat) -> DYLiveAmbientRGB {
        let t = min(1, max(0, amount))
        return DYLiveAmbientRGB(
            red: a.red * (1 - t) + b.red * t,
            green: a.green * (1 - t) + b.green * t,
            blue: a.blue * (1 - t) + b.blue * t)
    }

    /// 单色时只压低同一色相，不发明另一种颜色。
    static func variant(_ color: DYLiveAmbientRGB) -> DYLiveAmbientRGB {
        let (h, s, v) = hsv(color)
        return rgb(h: h, s: min(0.68, s * 0.82), v: max(0.05, v * 0.72))
    }

    static func hsv(_ color: DYLiveAmbientRGB) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        let r = min(1, max(0, color.red))
        let g = min(1, max(0, color.green))
        let b = min(1, max(0, color.blue))
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        var h: CGFloat = 0
        if delta > 0.0001 {
            if maxC == r { h = (g - b) / delta }
            else if maxC == g { h = 2 + (b - r) / delta }
            else { h = 4 + (r - g) / delta }
            h /= 6
            if h < 0 { h += 1 }
        }
        let saturation = maxC <= 0 ? 0 : delta / maxC
        return (h, saturation, maxC)
    }

    static func rgb(h: CGFloat, s: CGFloat, v: CGFloat) -> DYLiveAmbientRGB {
        let wrapped = h - floor(h)
        let sector = wrapped * 6
        let index = Int(sector) % 6
        let fraction = sector - CGFloat(Int(sector))
        let p = v * (1 - s)
        let q = v * (1 - fraction * s)
        let t = v * (1 - (1 - fraction) * s)
        switch index {
        case 0: return DYLiveAmbientRGB(red: v, green: t, blue: p)
        case 1: return DYLiveAmbientRGB(red: q, green: v, blue: p)
        case 2: return DYLiveAmbientRGB(red: p, green: v, blue: t)
        case 3: return DYLiveAmbientRGB(red: p, green: q, blue: v)
        case 4: return DYLiveAmbientRGB(red: t, green: p, blue: v)
        default: return DYLiveAmbientRGB(red: v, green: p, blue: q)
        }
    }

    static func whiteTextContrast(artwork: DYLiveAmbientRGB?, location: CGFloat) -> CGFloat {
        whiteTextContrast(on: backdrop(artwork: artwork, location: location))
    }

    static func whiteTextContrast(on color: DYLiveAmbientRGB) -> CGFloat {
        (1 + 0.05) / (relativeLuminance(color) + 0.05)
    }

    static func opacity(at location: CGFloat, stops: [DYLiveAmbientStop]) -> CGFloat {
        let t = min(1, max(0, location))
        guard let first = stops.first else { return 0 }
        if t <= first.location { return first.opacity }
        guard let last = stops.last else { return 0 }
        if t >= last.location { return last.opacity }
        for index in stops.indices.dropFirst() {
            let left = stops[index - 1]
            let right = stops[index]
            if t <= right.location {
                let span = right.location - left.location
                let u = span > 0 ? (t - left.location) / span : 0
                return left.opacity + (right.opacity - left.opacity) * u
            }
        }
        return last.opacity
    }

    private static func over(_ base: DYLiveAmbientRGB, _ color: DYLiveAmbientRGB, opacity: CGFloat) -> DYLiveAmbientRGB {
        let t = min(1, max(0, opacity))
        return DYLiveAmbientRGB(
            red: base.red * (1 - t) + color.red * t,
            green: base.green * (1 - t) + color.green * t,
            blue: base.blue * (1 - t) + color.blue * t)
    }

    private static func linear(_ channel: CGFloat) -> CGFloat {
        if channel <= 0.04045 { return channel / 12.92 }
        return pow((channel + 0.055) / 1.055, 2.4)
    }

    static func relativeLuminance(_ color: DYLiveAmbientRGB) -> CGFloat {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }
}

struct DYLiveAmbientPalette: Equatable, Sendable {
    var primary: DYLiveAmbientRGB
    var secondary: DYLiveAmbientRGB
    var sourceLuminance: CGFloat

    static let neutral = DYLiveAmbientPalette(
        primary: DYLiveAmbientTreatment.fallback,
        secondary: DYLiveAmbientTreatment.fallback,
        sourceLuminance: 0)

    /// 纯色样本没有面积信息。色相接近时退回同一色相的明暗变化。
    static func make(average: DYLiveAmbientRGB, accent: DYLiveAmbientRGB) -> DYLiveAmbientPalette {
        let averageHSV = DYLiveAmbientTreatment.hsv(average)
        let accentHSV = DYLiveAmbientTreatment.hsv(accent)
        let separated = accentHSV.s > 0.18 && DYLiveAmbientTreatment.hueDistance(accentHSV.h, averageHSV.h) > 0.05
        let secondarySource = separated ? accent : DYLiveAmbientTreatment.variant(average)
        return DYLiveAmbientPalette(
            primary: DYLiveAmbientTreatment.graded(average),
            secondary: DYLiveAmbientTreatment.graded(secondarySource, accent: true),
            sourceLuminance: DYLiveAmbientTreatment.relativeLuminance(average))
    }

    /// 按色相分桶，面积够大的颜色才进入主色或辅色。孤立的高饱和像素会被忽略。
    static func extract(from bitmap: DYLiveAmbientBitmap) -> DYLiveAmbientPalette {
        let count = bitmap.width * bitmap.height
        guard count > 0, bitmap.rgba.count == count * 4 else { return .neutral }
        let binCount = 12
        var weight = [Int](repeating: 0, count: binCount)
        var sumR = [CGFloat](repeating: 0, count: binCount)
        var sumG = [CGFloat](repeating: 0, count: binCount)
        var sumB = [CGFloat](repeating: 0, count: binCount)
        var allR: CGFloat = 0
        var allG: CGFloat = 0
        var allB: CGFloat = 0
        for index in 0..<count {
            let offset = index * 4
            let pixel = DYLiveAmbientRGB(
                red: CGFloat(bitmap.rgba[offset]) / 255,
                green: CGFloat(bitmap.rgba[offset + 1]) / 255,
                blue: CGFloat(bitmap.rgba[offset + 2]) / 255)
            allR += pixel.red
            allG += pixel.green
            allB += pixel.blue
            let (hue, saturation, value) = DYLiveAmbientTreatment.hsv(pixel)
            if saturation < 0.12 || value < 0.05 { continue }
            var bin = Int((hue * CGFloat(binCount)).rounded(.down))
            if bin >= binCount { bin = 0 }
            if bin < 0 { bin = 0 }
            weight[bin] += 1
            sumR[bin] += pixel.red
            sumG[bin] += pixel.green
            sumB[bin] += pixel.blue
        }
        let total = CGFloat(count)
        let global = DYLiveAmbientRGB(red: allR / total, green: allG / total, blue: allB / total)
        var first = -1
        var second = -1
        for bin in 0..<binCount where weight[bin] > 0 {
            if first < 0 || weight[bin] > weight[first] {
                second = first
                first = bin
            } else if second < 0 || weight[bin] > weight[second] {
                second = bin
            }
        }
        func average(_ bin: Int) -> DYLiveAmbientRGB {
            let samples = CGFloat(weight[bin])
            return DYLiveAmbientRGB(red: sumR[bin] / samples, green: sumG[bin] / samples, blue: sumB[bin] / samples)
        }
        let primaryRaw: DYLiveAmbientRGB
        if first >= 0 {
            let share = CGFloat(weight[first]) / total
            primaryRaw = DYLiveAmbientTreatment.mix(global, average(first), DYLiveAmbientTreatment.smoothstep(0.12, 0.30, share))
        } else {
            primaryRaw = global
        }
        var secondaryRaw = DYLiveAmbientTreatment.variant(primaryRaw)
        if second >= 0 {
            let share = CGFloat(weight[second]) / total
            let influence = DYLiveAmbientTreatment.smoothstep(0.08, 0.18, share)
            let gap = DYLiveAmbientTreatment.hueDistance(DYLiveAmbientTreatment.hsv(average(second)).h, DYLiveAmbientTreatment.hsv(primaryRaw).h)
            let separated = gap > 0.05 ? influence : 0
            secondaryRaw = DYLiveAmbientTreatment.mix(DYLiveAmbientTreatment.variant(primaryRaw), average(second), separated)
        }
        return DYLiveAmbientPalette(
            primary: DYLiveAmbientTreatment.graded(primaryRaw),
            secondary: DYLiveAmbientTreatment.graded(secondaryRaw, accent: true),
            sourceLuminance: DYLiveAmbientTreatment.relativeLuminance(global))
    }
}

struct DYLiveAmbientPrepared: Equatable, Sendable {
    var palette: DYLiveAmbientPalette
}

struct DYLiveAmbientBitmap: Equatable, Sendable {
    var width: Int
    var height: Int
    var rgba: [UInt8]
}

enum DYLiveAmbientBlur {
    static func boxBlur(_ source: DYLiveAmbientBitmap, radius: Int) -> DYLiveAmbientBitmap {
        guard radius > 0, source.width > 0, source.height > 0, source.rgba.count == source.width * source.height * 4 else {
            return source
        }
        let horizontal = blur(source, radius: radius, horizontal: true)
        return blur(horizontal, radius: radius, horizontal: false)
    }

    /// 三次盒式模糊。当前取色直接用缩小后的封面，不再为调色板跑这一步。
    static func soften(_ source: DYLiveAmbientBitmap) -> DYLiveAmbientBitmap {
        guard source.width > 0, source.height > 0 else { return source }
        let radius = max(2, min(source.width, source.height) / 5)
        var image = source
        for _ in 0..<3 {
            image = boxBlur(image, radius: radius)
        }
        return image
    }

    private static func blur(_ source: DYLiveAmbientBitmap, radius: Int, horizontal: Bool) -> DYLiveAmbientBitmap {
        let width = source.width
        let height = source.height
        var out = [UInt8](repeating: 0, count: source.rgba.count)
        let span = horizontal ? width : height
        let lines = horizontal ? height : width
        let window = radius * 2 + 1
        for line in 0..<lines {
            func sample(_ index: Int) -> (Int, Int, Int, Int) {
                let clamped = min(span - 1, max(0, index))
                let pixel = horizontal ? (line * width + clamped) * 4 : (clamped * width + line) * 4
                return (
                    Int(source.rgba[pixel]),
                    Int(source.rgba[pixel + 1]),
                    Int(source.rgba[pixel + 2]),
                    Int(source.rgba[pixel + 3]))
            }
            var sumR = 0
            var sumG = 0
            var sumB = 0
            var sumA = 0
            for index in -radius...radius {
                let pixel = sample(index)
                sumR += pixel.0
                sumG += pixel.1
                sumB += pixel.2
                sumA += pixel.3
            }
            for index in 0..<span {
                let pixel = horizontal ? (line * width + index) * 4 : (index * width + line) * 4
                out[pixel] = UInt8(sumR / window)
                out[pixel + 1] = UInt8(sumG / window)
                out[pixel + 2] = UInt8(sumB / window)
                out[pixel + 3] = UInt8(sumA / window)
                if index + 1 < span {
                    let remove = sample(index - radius)
                    let add = sample(index + radius + 1)
                    sumR += add.0 - remove.0
                    sumG += add.1 - remove.1
                    sumB += add.2 - remove.2
                    sumA += add.3 - remove.3
                }
            }
        }
        return DYLiveAmbientBitmap(width: width, height: height, rgba: out)
    }
}

/// 同一张封面只模糊一次。容量很小，只留最近几间房。
final class DYLiveAmbientMemo<Value> {
    private var stored: [String: Value] = [:]
    private var order: [String] = []
    private(set) var renders = 0
    let limit: Int

    init(limit: Int = 4) { self.limit = max(1, limit) }

    func peek(_ key: String) -> Value? {
        guard let hit = stored[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return hit
    }

    func resolve(key: String, render: () -> Value) -> Value {
        if let hit = peek(key) { return hit }
        renders += 1
        let value = render()
        stored[key] = value
        order.append(key)
        while stored.count > limit, let oldest = order.first {
            order.removeFirst()
            stored[oldest] = nil
        }
        return value
    }
}

// MARK: - ambient-treatment-end

private final class DYLiveAmbientBlurStore {
    static let shared = DYLiveAmbientBlurStore()
    private let memo = DYLiveAmbientMemo<DYLiveAmbientPrepared>(limit: 4)

    func peek(_ key: String) -> DYLiveAmbientPrepared? { memo.peek(key) }

    func resolve(key: String, render: () -> DYLiveAmbientPrepared) -> DYLiveAmbientPrepared {
        memo.resolve(key: key, render: render)
    }
}

extension DYLiveAmbientBitmap {
    static func scaled(from image: UIImage, maxPixel: Int) -> DYLiveAmbientBitmap? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth >= 1, pixelHeight >= 1 else { return nil }
        let cap = CGFloat(max(1, maxPixel))
        let ratio = min(1, cap / max(pixelWidth, pixelHeight))
        let width = max(1, Int((pixelWidth * ratio).rounded()))
        let height = max(1, Int((pixelHeight * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let small = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cg = small.cgImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drew = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        for index in stride(from: 3, to: rgba.count, by: 4) { rgba[index] = 255 }
        return DYLiveAmbientBitmap(width: width, height: height, rgba: rgba)
    }

    func uiImage() -> UIImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}

#if DEBUG
private enum DYLiveAmbientPreviewArt {
    static func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format)
        return renderer.image { context in
            UIColor(red: red, green: green, blue: blue, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }
}

private struct DYLiveAmbientPreview: View {
    var axis: DYLiveAmbientAxis
    var artwork: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DouyinLiveAmbientBackground(axis: axis, artwork: artwork)
            VStack(alignment: .leading, spacing: 6) {
                Text("主播名称").font(.headline)
                Text("评论在封面上保持可读").font(.subheadline)
            }
            .foregroundStyle(.white)
            .padding(16)
        }
    }
}

struct DouyinLiveAmbientBackground_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            DYLiveAmbientPreview(axis: .vertical, artwork: DYLiveAmbientPreviewArt.solid(1, 0.92, 0.15))
                .previewDisplayName("A 亮色")
            DYLiveAmbientPreview(axis: .horizontal, artwork: DYLiveAmbientPreviewArt.solid(0.1, 0.45, 1))
                .previewDisplayName("B 亮色")
            DYLiveAmbientPreview(axis: .vertical, artwork: DYLiveAmbientPreviewArt.solid(0.02, 0.02, 0.03))
                .previewDisplayName("A 暗色")
            DYLiveAmbientPreview(axis: .horizontal, artwork: nil)
                .previewDisplayName("B 无封面")
        }
        .frame(width: 390, height: 280)
        .previewLayout(.sizeThatFits)
    }
}
#endif
