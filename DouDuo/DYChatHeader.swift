import SwiftUI

struct DYChatHeader: View {
    let row: DYConversationRow
    var maximumWidth: CGFloat = 340
    let onProfile: (() -> Void)?

    var body: some View {
        Group {
            if let onProfile {
                Button(action: onProfile) { label }.buttonStyle(.plain)
                    .accessibilityLabel("\(row.name)，好友主页")
            } else {
                label.accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: maximumWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .glassEffect(onProfile == nil ? .regular : .regular.interactive(), in: .capsule)
        .accessibilityIdentifier("douyin.messages.chat.header")
    }

    private var label: some View {
        HStack(spacing: 8) {
            CachedAsyncImage(url: row.avatar.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
            }
            .frame(width: 36, height: 36).clipShape(.circle)
            .accessibilityHidden(true)
            Text(row.name).font(.headline).lineLimit(1)
            if let streak = row.streak { DYStreakBadge(streak: streak) }
            if onProfile != nil {
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
        .contentShape(.capsule)
    }
}
