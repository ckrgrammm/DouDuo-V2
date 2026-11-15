import SwiftUI

struct DYChatComposer: View {
    @ObservedObject var model: DYChatComposerModel
    var active: Bool
    @State private var focused = false

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.error {
                HStack(spacing: 12) {
                    Text(error)
                    Button("复制输入并恢复") { Task { await model.copyAndRecover() } }
                }
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .accessibilityIdentifier("douyin.messages.composer.error")
            }
            HStack(spacing: 0) {
                DYChatTextEditor(text: model.text, active: active, editable: !model.working, focused: $focused, onEdit: model.edit)
                    .padding(.vertical, 8)
                    .overlay(alignment: .topLeading) {
                        if model.text.isEmpty {
                            Text("发送消息").font(.body).foregroundStyle(.secondary)
                                .padding(.top, 8).allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.leading, 20).padding(.trailing, 6)
                action(.attachment, label: "附件", image: "MessageAttachment", size: 28)
                action(.emoji, label: "表情", image: "MessageEmoji", size: 28)
                action(.send, label: "发送", image: "MessageSend", size: 32)
                    .opacity(model.canSend ? 1 : 0.35)
                    .disabled(!model.canSend)
            }
            .padding(.trailing, 8)
            .frame(minHeight: 44)
            .glassEffect(.regular, in: .capsule)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.height = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("douyin.messages.composer")
        }
        .onChange(of: active) { _, active in if !active { focused = false } }
        .onChange(of: focused) { _, focused in model.isEditing = focused }
        .onDisappear { model.isEditing = false }
    }

    private func action(_ action: DYChatComposerBridge.Action, label: String, image: String, size: CGFloat) -> some View {
        Button {
            if action != .send { focused = false }
            Task { await model.perform(action) }
        } label: {
            Image(image).resizable().scaledToFit().frame(width: size, height: size)
                .frame(width: 40, height: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("douyin.messages.composer." + action.rawValue)
        .disabled(model.working || !active)
    }
}
