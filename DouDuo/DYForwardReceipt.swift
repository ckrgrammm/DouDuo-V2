import Foundation

/// A receipt exists only after the official business callback confirms success.
struct DYForwardReceipt: Identifiable, Equatable {
    let id = UUID()
    let contact: DYForwardContact
    let workID: String
    let accountScope: String

    init?(state: String?, source: String?, contact: DYForwardContact, workID: String, accountScope: String) {
        guard state == "sent", source == "callback",
              !workID.isEmpty, !accountScope.isEmpty else { return nil }
        self.contact = contact
        self.workID = workID
        self.accountScope = accountScope
    }
}
