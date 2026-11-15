import SwiftUI

/// Keeps the conversation visible even at the narrowest sidebar setting.
struct DYMessageDivider: View {
    @Binding var fraction: Double
    let width: CGFloat
    @State private var dragStart: CGFloat?
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        Color.clear
        .frame(width: 44)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = DYMessageSidebarLayout.listWidth(fraction: fraction, in: width) }
                    let sign: Double = layoutDirection == .rightToLeft ? -1 : 1
                    fraction = DYMessageSidebarLayout.fraction(startWidth: dragStart ?? 280,
                        translation: sign * value.translation.width, in: width)
                }
                .onEnded { _ in dragStart = nil }
        )
        .accessibilityElement()
        .accessibilityLabel("调整消息列表宽度")
        .accessibilityValue(fraction <= 0 ? "头像列表" : "\(Int(DYMessageSidebarLayout.listWidth(fraction: fraction, in: width) / max(width, 1) * 100))%")
        .accessibilityHint("向左或向右拖动，调整列表和聊天的比例")
        .accessibilityAdjustableAction { direction in
            let current = DYMessageSidebarLayout.listWidth(fraction: fraction, in: width)
            fraction = DYMessageSidebarLayout.fraction(startWidth: current,
                translation: direction == .increment ? 56 : -56, in: width)
        }
        .accessibilityIdentifier("douyin.messages.divider")
    }
}
