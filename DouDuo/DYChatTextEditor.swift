import SwiftUI
import UIKit

/// A native text responder avoids WKWebView's form-navigation accessory bar.
/// UITextView preserves marked Chinese input, selection, undo and multiline text.
struct DYChatTextEditor: UIViewRepresentable {
    let text: String
    let active: Bool
    let editable: Bool
    @Binding var focused: Bool
    let onEdit: (String, NSRange) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textColor = .white
        view.tintColor = UIColor(red: 1, green: 0.17, blue: 0.33, alpha: 1)
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.keyboardAppearance = .dark
        view.inputAccessoryView = nil
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
        view.accessibilityLabel = "发送消息"
        view.accessibilityIdentifier = "douyin.messages.composer.editor"
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = editable
        if view.text != text, view.markedTextRange == nil {
            context.coordinator.updating = true
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
            context.coordinator.updating = false
        }
        if !active || !focused {
            if view.isFirstResponder {
                context.coordinator.updating = true
                view.resignFirstResponder()
                context.coordinator.updating = false
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // Let the HStack center a single line beside the 44 pt actions. Giving
        // UITextView a taller minimum leaves its glyphs pinned to the top.
        let height = max(ceil(uiView.font?.lineHeight ?? 20), min(112, fitted.height))
        uiView.isScrollEnabled = fitted.height > 112
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: DYChatTextEditor
        var updating = false
        init(_ parent: DYChatTextEditor) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) {
            if !updating && parent.focused { parent.focused = false }
        }
        func textViewDidChange(_ textView: UITextView) {
            guard !updating else { return }
            parent.onEdit(textView.text, textView.selectedRange)
            textView.invalidateIntrinsicContentSize()
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating, textView.isFirstResponder, textView.markedTextRange == nil else { return }
            parent.onEdit(textView.text, textView.selectedRange)
        }
    }
}
