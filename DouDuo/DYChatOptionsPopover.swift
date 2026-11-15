import SwiftUI
import WebKit

/// Reads the currently available official controls rather than inventing a menu.
struct DYChatOptionsPopover: View {
    let web: WKWebView
    let conversationID: String
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var options: [DYChatOption] = []
    @State private var loading = true
    @State private var working: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("聊天设置").font(.headline)
                Spacer()
                Button("关闭", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .accessibilityIdentifier("douyin.messages.options.close")
            }
            .padding(.leading, 18).padding(.trailing, 8).padding(.top, 8)
            Divider().padding(.horizontal, 18).padding(.bottom, 6)
            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(options) { option in
                            Button { Task { await perform(option) } } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: symbol(for: option.title))
                                        .font(.body).foregroundStyle(.secondary).frame(width: 22)
                                    Text(option.title).multilineTextAlignment(.leading)
                                    Spacer(minLength: 16)
                                    if working == option.id {
                                        ProgressView()
                                    } else if let checked = option.checked {
                                        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(checked ? theme.accent.color(for: scheme) : .secondary)
                                    } else {
                                        Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(minHeight: 48)
                                .padding(.horizontal, 18).padding(.vertical, 2)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(working != nil || option.disabled)
                            .accessibilityValue(option.checked.map { $0 ? "已开启" : "已关闭" } ?? "")
                        }
                        if let error {
                            Text(error).font(.footnote).foregroundStyle(.secondary).padding(16)
                            Button("重试") { Task { await reload() } }.padding(.bottom, 16)
                        }
                    }
                }
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(idealWidth: 300, maxWidth: 320)
        .padding(.bottom, 8)
        .tint(theme.accent.color(for: scheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.messages.options")
        .task { await reload() }
    }

    private func symbol(for title: String) -> String {
        if title.contains("免打扰") { return "bell.slash" }
        if title.contains("置顶") { return "pin" }
        if title.contains("举报") { return "flag" }
        if title.contains("退出") { return "rectangle.portrait.and.arrow.right" }
        return "ellipsis.circle"
    }

    private func reload() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            options = try await DYChatWebBridge.options(web, id: conversationID)
            if options.isEmpty { error = "暂时无法读取聊天设置，请重试。" }
        } catch {
            self.error = "暂时无法读取聊天设置，请重试。"
        }
    }

    private func perform(_ option: DYChatOption) async {
        guard working == nil else { return }
        working = option.id
        defer { working = nil }
        do {
            try await DYChatWebBridge.performOption(option, web: web, id: conversationID)
            onChange()
            if option.checked == nil { dismiss() } else { await reload() }
        } catch {
            self.error = "操作未完成，请稍后重试。"
        }
    }
}
