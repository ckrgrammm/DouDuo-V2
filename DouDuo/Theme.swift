// 主题垫片：DouDuo 只有沉浸式黑底播放界面，用固定配色实现 無為 主题令牌的同名接口，业务代码零改动复用。
import SwiftUI

struct DDColor {
    let light: Color
    let dark: Color
    init(_ c: Color) { light = c; dark = c }
    init(light: Color, dark: Color) { self.light = light; self.dark = dark }
    func color(for scheme: ColorScheme) -> Color { scheme == .dark ? dark : light }
}

enum DDFontSize { case caption, body, headline, title, displayLarge, splash }

struct DDTheme {
    struct Media {
        let scrim = DDColor(.black.opacity(0.35))
        let strongScrim = DDColor(.black)
        let onMedia = DDColor(.white)
        let onMediaSecondary = DDColor(.white.opacity(0.72))
        let chromeFill = DDColor(.black.opacity(0.35))
    }
    struct Status {
        let danger = DDColor(Color(red: 1.0, green: 0.17, blue: 0.33))     // 抖音红
        let warning = DDColor(.orange)
        let success = DDColor(.green)
    }
    struct Typography {
        func pointSize(_ s: DDFontSize) -> CGFloat {
            switch s {
            case .caption: 12
            case .body: 15
            case .headline: 17
            case .title: 22
            case .displayLarge: 29
            case .splash: 52
            }
        }
    }
    let media = Media()
    let status = Status()
    let typography = Typography()
    let accent = DDColor(Color(red: 1.0, green: 0.17, blue: 0.33))
}

extension EnvironmentValues {
    @Entry var appTheme = DDTheme()
    /// 界面放大系数：目前固定 1（不做全局缩放）；PR 里播放器部分用到，先给个默认值
    @Entry var ddScale: CGFloat = 1
}

enum DDElevation { case mediaLabel, floatingPanel }

extension View {
    func themeShadow(_ e: DDElevation) -> some View {
        switch e {
        case .mediaLabel: shadow(color: .black.opacity(0.45), radius: 3, y: 1)
        case .floatingPanel: shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
    }
}

extension ShapeStyle where Self == Color {
    static var themeTextPrimary: Color { .primary }
    static var themeTextSecondary: Color { .secondary }
}

// MARK: - 液态玻璃圆按钮（iOS 26+ glassEffect；低版本回退 ultraThinMaterial 圆底）

extension View {
    /// 液态玻璃圆底：iOS 26+ 用 `.glassEffect(.regular.interactive(), in: .circle)`；
    /// 传入 tint 表示选中态（点赞红 / 收藏黄），用 `.regular.tint(color.opacity(0.22)).interactive()`；
    /// iOS 26 以下回退 `.ultraThinMaterial` 圆底（选中态叠一层 22% 的 tint）。
    @ViewBuilder
    func ddGlassCircle(_ tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint.opacity(0.22)).interactive(), in: .circle)
            } else {
                self.glassEffect(.regular.interactive(), in: .circle)
            }
        } else {
            self
                .background(tint.map { $0.opacity(0.22) } ?? .clear, in: Circle())
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}

extension View {
    /// 竖向液态玻璃胶囊（小红书式右侧栏底板）
    @ViewBuilder
    /// clear：更通透的玻璃（压在视频画面上用），能看清后面的内容
    func ddGlassCapsule(clear: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(clear ? .clear.interactive() : .regular.interactive(), in: .capsule)
        } else {
            self.background(.ultraThinMaterial.opacity(clear ? 0.45 : 1), in: Capsule())
        }
    }
}

struct GlassBackground: View {
    var body: some View { Rectangle().fill(.regularMaterial).ignoresSafeArea() }
}

enum WuWeiDesign {
    enum Spacing {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }
}
