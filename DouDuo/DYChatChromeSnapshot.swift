import Foundation

struct DYChatChromeSnapshot: Decodable, Equatable {
    let id: String
    let streak: DYConversationStreak?
}

struct DYChatOption: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let checked: Bool?
    let disabled: Bool
}
