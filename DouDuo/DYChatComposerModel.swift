import SwiftUI
import WebKit

@MainActor
final class DYChatComposerModel: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var ready = false
    @Published private(set) var working = false
    @Published private(set) var error: String?
    @Published var isEditing = false
    var canSend: Bool { ready && !deliveryUncertain && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var height: CGFloat = 44
    var bottomInset: CGFloat { isEditing ? 8 : 24 }

    private weak var web: WKWebView?
    private var conversationID = ""
    private var acknowledgedText = ""
    private var selection = NSRange(location: 0, length: 0)
    private var emojiSelection: NSRange?
    private var editRevision = 0
    private var accountScope = ""
    private var drafts: [String: (text: String, previous: String, uncertain: Bool)] = [:]
    private var deliveryUncertain = false

    func setAccountScope(_ scope: String) {
        guard scope != accountScope else { return }
        disconnect()
        drafts.removeAll()
        accountScope = scope
    }

    func disconnect() {
        if !conversationID.isEmpty, text != acknowledgedText || deliveryUncertain {
            drafts[conversationID] = (text, acknowledgedText, deliveryUncertain)
        }
        conversationID = ""
        web = nil
        text = ""
        acknowledgedText = ""
        ready = false
        error = nil
        selection = NSRange(location: 0, length: 0)
        emojiSelection = nil
        deliveryUncertain = false
        editRevision += 1
    }

    func refresh(web: WKWebView, id: String) async {
        if conversationID != id || self.web !== web {
            disconnect()
            conversationID = id
            self.web = web
        }
        guard !working else { return }
        let revision = editRevision
        guard let snapshot = try? await DYChatComposerBridge.read(web, id: id, height: height, bottom: bottomInset),
              !Task.isCancelled, conversationID == id, editRevision == revision, !working else { return }
        if !ready {
            let draft = drafts.removeValue(forKey: id)
            acknowledgedText = draft?.previous ?? snapshot.text
            replaceLocalText(draft?.text ?? snapshot.text)
            deliveryUncertain = draft?.uncertain ?? false
            if deliveryUncertain { error = "发送结果未确认，请先查看聊天记录。" }
            ready = true
        }
        if let emojiSelection, snapshot.text != acknowledgedText {
            self.emojiSelection = nil
            if text == acknowledgedText {
                replaceLocalText(snapshot.text)
                acknowledgedText = snapshot.text
            } else if snapshot.text.hasPrefix(acknowledgedText) {
                let inserted = String(snapshot.text.dropFirst(acknowledgedText.count))
                let nsText = text as NSString
                let start = min(emojiSelection.location, nsText.length)
                let length = min(emojiSelection.length, nsText.length - start)
                replaceLocalText(nsText.replacingCharacters(in: NSRange(location: start, length: length), with: inserted))
                acknowledgedText = snapshot.text
            }
        } else if !deliveryUncertain, text == acknowledgedText, snapshot.text != acknowledgedText {
            acknowledgedText = snapshot.text
            replaceLocalText(snapshot.text)
        }
    }

    func edit(text: String, selection: NSRange) {
        guard ready, !working else { return }
        self.selection = selection
        guard self.text != text else { return }
        self.text = text
        emojiSelection = nil
        editRevision += 1
        if !deliveryUncertain { error = nil }
    }

    private func replaceLocalText(_ text: String) {
        self.text = text
        selection = NSRange(location: (text as NSString).length, length: 0)
        editRevision += 1
    }

    func isConnected(to id: String?) -> Bool { ready && id == conversationID }

    func copyAndRecover() async {
        guard let web, !working else { return }
        let id = conversationID
        let revision = editRevision
        UIPasteboard.general.string = text
        guard let snapshot = try? await DYChatComposerBridge.read(web, id: id, height: height, bottom: bottomInset),
              conversationID == id, self.web === web, revision == editRevision, !working else { return }
        replaceLocalText(snapshot.text)
        acknowledgedText = snapshot.text
        deliveryUncertain = false
        error = nil
    }

    func perform(_ action: DYChatComposerBridge.Action) async {
        guard !working, ready, let web, action != .send || canSend else { return }
        working = true
        defer { working = false }
        let id = conversationID
        let scope = accountScope
        let draft = text
        let previous = acknowledgedText
        error = nil
        if action == .send {
            do {
                _ = try await DYChatComposerBridge.edit(web, id: id, previous: previous, text: draft)
                guard conversationID == id, self.web === web, accountScope == scope, !Task.isCancelled else { return }
                acknowledgedText = draft
            } catch {
                guard conversationID == id, self.web === web, accountScope == scope else { return }
                #if DEBUG
                let failure = error as? DYChatComposerBridge.EditFailure ?? .bridgeUnavailable
                DYLiveModel.log("DDCHAT_DRAFT_SYNC \(failure.rawValue)")
                #endif
                self.error = "草稿未同步，请再次点发送。"
                return
            }
        }
        let hasLocalDraft = text != acknowledgedText
        let webSelection = action == .emoji && hasLocalDraft
            ? NSRange(location: (acknowledgedText as NSString).length, length: 0) : selection
        do {
            let result = try await DYChatComposerBridge.act(web, id: id, action: action,
                expected: acknowledgedText, selection: webSelection)
            guard conversationID == id, self.web === web, accountScope == scope else { return }
            if action == .emoji { emojiSelection = selection }
            if action == .send {
                acknowledgedText = result.text
                replaceLocalText(result.text)
            }
        } catch {
            guard conversationID == id, self.web === web, accountScope == scope else { return }
            if action == .send, (error as? DYChatComposerBridge.EditFailure) != .sendUnavailable {
                deliveryUncertain = true
                self.error = "发送结果未确认，请先查看聊天记录。"
            } else {
                self.error = action == .send ? "暂时无法发送，请再次点发送。" : "操作未完成，请重试。"
            }
        }
    }
}
