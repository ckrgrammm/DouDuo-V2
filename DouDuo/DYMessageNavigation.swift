/// One master-detail selection, independent of display size or device pose.
/// Returning true from back() asks the caller to close the message center.
struct DYMessageNavigation {
    enum Detail: Equatable {
        case category(DYMsgRoute)
        case chat(String, origin: DYMsgRoute?)
    }
    private(set) var detail: Detail?
    var hasDetail: Bool { detail != nil }
    var isChat: Bool {
        if case .chat = detail { return true }
        return false
    }
    var category: DYMsgRoute? {
        switch detail {
        case .category(let route): return route
        case .chat(_, let origin): return origin
        case nil: return nil
        }
    }
    var chatID: String? {
        if case .chat(let id, _) = detail { return id }
        return nil
    }
    mutating func select(_ route: DYMsgRoute) { detail = .category(route) }
    mutating func openChat(_ id: String, from route: DYMsgRoute?) { detail = .chat(id, origin: route) }
    mutating func back() -> Bool {
        switch detail {
        case .chat(_, let origin): detail = origin.map(Detail.category); return false
        case .category: detail = nil; return false
        case nil: return true
        }
    }
}
