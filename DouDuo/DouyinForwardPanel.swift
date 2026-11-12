import SwiftUI

struct DYForwardContact: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let avatar: String?
    /// 1：个人；2：群聊。
    let kind: Int
}

struct DYForwardPanelAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
}

/// 仅负责原生面板内容。父视图控制视频上方的位置、可用宽度、遮罩和发送确认。
/// 联系人与可用操作均由父视图传入；不在这里读取网页或发送消息。
struct DYNativeForwardPanel: View {
    let contacts: [DYForwardContact]
    let loading: Bool
    let status: String
    let actions: [DYForwardPanelAction]
    /// 已勾选的联系人；点头像切换勾选，由「发送给 N 人」统一确认。
    var selected: Set<String> = []
    var onSend: () -> Void = {}
    let onContact: (DYForwardContact) -> Void
    let onAction: (String) -> Void
    let onClose: () -> Void

    @ScaledMetric(relativeTo: .body) private var itemWidth: CGFloat = 84
    private let avatarSize: CGFloat = 60
    private let inset = WuWeiDesign.Spacing.lg

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if contacts.isEmpty {
                contactStatus
                    .frame(maxWidth: .infinity, minHeight: avatarSize + inset * 2)
                    .padding(.horizontal, inset)
            } else {
                contactRow
                if !selected.isEmpty {
                    Button(action: onSend) {
                        Text("发送给 \(selected.count) 人")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading)
                    .padding(.horizontal, inset)
                    .padding(.top, WuWeiDesign.Spacing.md)
                    .accessibilityIdentifier("douyin.forward.send")
                }
                if loading || !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contactStatus
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, inset)
                        .padding(.top, WuWeiDesign.Spacing.md)
                }
            }

            if !actions.isEmpty {
                actionRow
                    .padding(.top, inset * 2)
            }
        }
        .padding(.bottom, inset * 2)
        .foregroundStyle(.themeTextPrimary)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: inset * 2, style: .continuous)
        )
        .themeShadow(.floatingPanel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.forward.panel")
    }

    private var header: some View {
        HStack(spacing: WuWeiDesign.Spacing.md) {
            Text("分享给")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: inset * 2, height: inset * 2)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭转发面板")
            .accessibilityIdentifier("douyin.forward.close")
        }
        .padding(.leading, inset)
        .padding(.trailing, WuWeiDesign.Spacing.sm)
        .padding(.top, WuWeiDesign.Spacing.sm)
        .padding(.bottom, inset)
    }

    private var contactRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: WuWeiDesign.Spacing.sm) {
                ForEach(contacts) { contact in
                    Button { onContact(contact) } label: {
                        VStack(spacing: WuWeiDesign.Spacing.sm) {
                            CachedAsyncImage(url: contact.avatar.flatMap(URL.init(string:))) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Circle()
                                    .fill(Color(uiColor: .tertiarySystemFill))
                                    .overlay {
                                        Image(systemName: contact.kind == 2 ? "person.2.fill" : "person.fill")
                                            .font(.title2)
                                            .foregroundStyle(.themeTextSecondary)
                                    }
                            }
                            .frame(width: avatarSize, height: avatarSize)
                            .clipShape(Circle())
                            .overlay(alignment: .bottomTrailing) {
                                if selected.contains(contact.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.white, Color.accentColor)
                                        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                                }
                            }
                            .accessibilityHidden(true)

                            Text(contact.name)
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(width: itemWidth)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(contact.name)
                    .accessibilityHint(contact.kind == 2 ? "选择群聊，可多选，确认后发送" : "选择联系人，可多选，确认后发送")
                    .accessibilityAddTraits(selected.contains(contact.id) ? .isSelected : [])
                    .accessibilityIdentifier("douyin.forward.contact.\(contact.id)")
                }
            }
            .padding(.horizontal, inset)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var contactStatus: some View {
        HStack(spacing: WuWeiDesign.Spacing.sm) {
            if loading {
                ProgressView()
                    .accessibilityLabel("正在加载分享联系人")
            }
            Text(statusText)
                .font(.body)
                .foregroundStyle(.themeTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, WuWeiDesign.Spacing.sm)
    }

    private var statusText: String {
        if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return status }
        return loading ? "正在加载分享联系人…" : "暂无可分享的联系人"
    }

    private var actionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: WuWeiDesign.Spacing.sm) {
                ForEach(actions) { action in
                    Button { onAction(action.id) } label: {
                        VStack(spacing: WuWeiDesign.Spacing.md) {
                            Image(systemName: action.symbol)
                                .font(.title2.weight(.semibold))
                                .frame(width: avatarSize, height: avatarSize)
                                .background(Color(uiColor: .systemBackground), in: Circle())
                                .accessibilityHidden(true)
                            Text(action.title)
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: itemWidth)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(action.title)
                    .accessibilityIdentifier("douyin.forward.action.\(action.id)")
                }
            }
            .padding(.horizontal, inset)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
