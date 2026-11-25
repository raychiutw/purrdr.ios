import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 狀態 sheet 的「做完再送」開關(#305、#349:開關從輸入列移到狀態 sheet)。
/// 開著時送出的訊息排進主機的佇列、Agent 做完後依序送出。SSH 主機、舊版主機服務與唯讀裝置停用，原因寫在開關下方(`SendWhenDoneModel.unavailableReason`)。
struct SendWhenDoneToggle: View {
    @Bindable var model: SendWhenDoneModel
    var identifier = "status.sendWhenDone"

    var body: some View {
        Toggle(isOn: $model.isRequested) {
            Label("Send When Done", systemImage: "hourglass")
        }
        .disabled(model.availability != .available)
        .accessibilityIdentifier(identifier)
    }
}

/// 對話最下面的 Send When Done 佇列(#305):分隔線「Sent in order when done」,暫停原因在泡泡上方，
/// 編號的虛線泡泡依送出順序;點泡泡可編輯(放回輸入框)、往前或往後移動一格調整順序、或刪除。
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
                // 調整送出順序:往前或往後一格(VoiceOver 也從這裡操作)。
                if model.canMove(item.id, by: -1) {
                    Button("Move Up", systemImage: "arrow.up") { Task { await model.move(item.id, by: -1) } }
                        .accessibilityIdentifier("conversation.sendWhenDone.moveUp")
                }
                if model.canMove(item.id, by: 1) {
                    Button("Move Down", systemImage: "arrow.down") { Task { await model.move(item.id, by: 1) } }
                        .accessibilityIdentifier("conversation.sendWhenDone.moveDown")
                }
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.remove(item.id) } }
                    .accessibilityIdentifier("conversation.sendWhenDone.delete")
            } label: {
                PendingBubbleBody(text: item.text, number: number)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Queued message \(number): \(item.text)"))
            .accessibilityHint(Text("Opens options to edit, reorder, or delete."))
            .accessibilityIdentifier("conversation.sendWhenDone.item")
        }
    }
}
