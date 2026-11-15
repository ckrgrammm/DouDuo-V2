import SwiftUI

struct DYConversationCell: View {
    let row: DYConversationRow
    var compact = false

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 6) {
                    avatar
                    Text(row.name).font(.caption).lineLimit(1)
                    if let streak = row.streak { DYStreakBadge(streak: streak) }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) { badge }
            } else {
                HStack(spacing: 12) {
                    avatar
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(row.name).font(.body.weight(.semibold)).lineLimit(1)
                            if let streak = row.streak { DYStreakBadge(streak: streak) }
                        }
                        Text(row.preview).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(row.time).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        badge
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, compact ? 8 : 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 76)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 0.5)
                .padding(.leading, compact ? 8 : 76).padding(.trailing, compact ? 8 : 16)
        }
        .contentShape(.rect)
    }

    private var avatar: some View {
        CachedAsyncImage(url: row.avatar.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                .foregroundStyle(.secondary)
        }
        .frame(width: 48, height: 48).clipShape(.circle)
        .accessibilityHidden(true)
    }

    @ContentBuilder private var badge: some View {
        if !row.badge.isEmpty {
            Text(row.badge).font(.caption2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.red, in: .capsule)
        }
    }
}
