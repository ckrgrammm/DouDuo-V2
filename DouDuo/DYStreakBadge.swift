import SwiftUI

struct DYStreakBadge: View {
    let streak: DYConversationStreak

    var body: some View {
        HStack(spacing: 3) {
            CachedAsyncImage(url: streak.icon.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "flame.fill").foregroundStyle(.secondary)
            }
            .frame(width: 18, height: 18)
            if !streak.text.isEmpty {
                Text(streak.text).font(.caption.weight(.medium)).monospacedDigit()
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("火花，\(streak.text)")
        .accessibilityIdentifier("douyin.conversation.streak")
    }
}
