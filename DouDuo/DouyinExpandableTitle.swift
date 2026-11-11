import SwiftUI

/// 根据真实可用宽度选布局：完整标题能放下一行时，没有展开按钮；放不下才提供折叠操作。
struct DYExpandableTitle: View {
    let text: String
    let foreground: Color
    let secondary: Color
    @State private var expanded = false

    private var oneLine: String { text.split(whereSeparator: \.isNewline).joined(separator: " ") }

    @ScaledMetric(relativeTo: .footnote) private var expandedHeight: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if expanded {
                ScrollView(.vertical) {
                    Text(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("douyin.description")
                }
                .frame(maxHeight: expandedHeight)
                .scrollIndicators(.visible)
                toggle.frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                ViewThatFits(in: .horizontal) {
                    Text(oneLine)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("douyin.description")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(oneLine)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onTapGesture { expanded = true }
                            .accessibilityIdentifier("douyin.description")
                        toggle
                    }
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(foreground)
        .frame(maxWidth: 360, alignment: .leading)
    }

    private var toggle: some View {
        Button(expanded ? "收起" : "展开") { expanded.toggle() }
            .font(.caption)
            .foregroundStyle(secondary)
            .fixedSize()
            .buttonStyle(.plain)
            .accessibilityIdentifier("douyin.description.toggle")
    }
}

#if DEBUG
struct DYTitleLayoutProbe: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            DYExpandableTitle(text: "短标题", foreground: .primary, secondary: .secondary)
                .frame(width: 280).accessibilityElement(children: .contain).accessibilityIdentifier("title.short")
            DYExpandableTitle(text: String(repeating: "这是一段需要折叠的长标题，", count: 8), foreground: .primary, secondary: .secondary)
                .frame(width: 280).accessibilityElement(children: .contain).accessibilityIdentifier("title.long")
        }
        .padding()
    }
}
#endif
