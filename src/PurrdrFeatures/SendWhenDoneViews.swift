import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 輸入列的「做完再送」膠囊(#305,原型 #t305-b):高度同加入圖片鈕、底色同(卡片內的 bordered)。
/// 開著時送出的訊息排進主機的佇列、Agent 做完後依序送出。SSH 主機、舊版主機服務與唯讀裝置停用，點了說明原因。
struct SendWhenDoneToggle: View {
    @Bindable var model: SendWhenDoneModel
    var identifier = "composer.sendWhenDone"
    /// 放在輸入列的玻璃卡片裡(#187):不再疊玻璃。
    var isInCard = true

    var body: some View {
        Button {
            model.toggle()
        } label: {
            Label {
                Text("Send When Done")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            } icon: {
                Image(systemName: model.isEnabled ? "checkmark.circle.fill" : "hourglass")
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
        }
        .composerSecondaryButtonStyle(isInCard: isInCard)
        .buttonBorderShape(.capsule)
        .frame(minHeight: 44)
        .opacity(model.availability == .available ? 1 : 0.5)
        .accessibilityLabel(Text("Send When Done"))
        .accessibilityValue(Text(model.isEnabled ? "On" : "Off"))
        .accessibilityAddTraits(.isToggle)
        .accessibilityHint(Text(model.availability == .available ? "Queues your message and sends it when the agent is done." : Self.explanation(for: model.availability)))
        .accessibilityIdentifier(identifier)
        .alert("Send When Done", isPresented: $model.explainsUnavailability) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(Self.explanation(for: model.availability))
        }
    }

    /// 停用的原因(點開關時顯示)。
    static func explanation(for availability: SendWhenDoneAvailability) -> LocalizedStringKey {
        switch availability {
        case .available: ""
        case .needsHostService:
            "Send When Done needs the Purrdr host service (0.7.0 or later) on this host. Hosts connected over SSH can’t use it."
        case .readOnlyDevice:
            "This device is paired read-only, so it can’t queue messages."
        }
    }
}

/// 對話最下面的 Send When Done 佇列(#305):分隔線「Sent in order when done」,暫停原因在泡泡上方，
/// 編號的虛線泡泡依送出順序;點泡泡可編輯(放回輸入框)或刪除。
struct SendWhenDoneQueueView: View {
    let conversation: ConversationModel
    let model: SendWhenDoneModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            divider
            if model.pause == .sessionChanged {
                Label("Paused: this chat changed on the host. Edit or delete the first message to continue.", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("conversation.sendWhenDone.paused")
            }
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                bubble(item, number: index + 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.sendWhenDone")
    }

    private var divider: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.separator).frame(height: 1)
            Text("Sent in order when done")
                .font(.caption)
                .foregroundStyle(.secondaryText)
                .fixedSize()
            Rectangle().fill(.separator).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func bubble(_ item: SendWhenDoneItem, number: Int) -> some View {
        HStack {
            Spacer(minLength: 44)
            Menu {
                Button("Edit", systemImage: "pencil") { Task { await conversation.editSendWhenDone(item.id) } }
                    .accessibilityIdentifier("conversation.sendWhenDone.edit")
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.remove(item.id) } }
                    .accessibilityIdentifier("conversation.sendWhenDone.delete")
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(number)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondaryText)
                    Text(item.text)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.secondaryText, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .opacity(0.75)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Queued message \(number): \(item.text)"))
            .accessibilityHint(Text("Opens options to edit or delete."))
            .accessibilityIdentifier("conversation.sendWhenDone.item")
        }
    }
}
