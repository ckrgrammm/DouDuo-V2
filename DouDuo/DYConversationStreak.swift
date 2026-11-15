import Foundation

/// The official IM badge supplies both the image and its text, including inactive streaks.
struct DYConversationStreak: Codable, Equatable {
    let text: String
    let icon: String?
}
