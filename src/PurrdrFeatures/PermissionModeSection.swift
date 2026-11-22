import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 標題面板下半的權限模式選項(#380,取代 #306 的輸入列膠囊與選擇 sheet):一般／接受編輯／規劃／略過權限的勾選列直接展開,
/// 選定就切換(同 DESIGN.md「選擇控制」)。Agent 在等你回覆、唯讀裝置或離線時停用並說明原因(Shift+Tab 在等回覆時會變成「核准」);
/// 切換失敗留在這裡說明並有「再試一次」。
struct PermissionModeSection: View {
    let model: ConversationModel

    private var selection: Binding<AgentPermissionMode> {
        Binding(
            get: { model.switchingPermissionMode ?? model.permissionMode ?? .normal },
            set: { mode in Task { await model.setPermissionMode(mode) } }
        )
    }

    var body: some View {
        Section {
            Picker(String(localized: "Permission Mode"), selection: selection) {
                ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
                    Text(verbatim: mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(!model.canSwitchPermissionMode)
            .accessibilityIdentifier("permissionMode.picker")
        } header: {
            HStack(spacing: 6) {
                Text("Permission Mode")
                if model.isSwitchingPermissionMode {
                    ProgressView().controlSize(.mini)
                }
            }
        } footer: {
            if let lock = model.permissionModeLock {
                Text(lock.explanation)
                    .accessibilityIdentifier("permissionMode.lock")
            }
        }
        if let failure = model.permissionModeFailure {
            Section {
                Label(failure.text, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .accessibilityIdentifier("permissionMode.failure")
                if failure.target != nil {
                    Button("Try Again") {
                        Task { await model.retryPermissionMode() }
                    }
                    .disabled(model.isSwitchingPermissionMode)
                    .accessibilityIdentifier("permissionMode.retry")
                }
            }
        }
    }
}

extension ConversationModel.PermissionModeLock {
    /// 選項停用時說明為什麼。
    var explanation: LocalizedStringKey {
        switch self {
        case .readOnlyDevice: "This device is paired read-only, so it can’t change the mode."
        case .offline: "Can’t reach the host, so the mode can’t be changed."
        case .waitingForYou: "The agent is waiting for your reply. Answer first, then change the mode."
        }
    }
}

extension PermissionModeFailure {
    var text: String {
        switch self {
        case .notReached(let attempts, let target):
            String(localized: "Tried \(attempts) times, but the screen doesn’t show \(target.displayName) mode. Try again, or check the terminal.")
        case .bypassUnavailable:
            String(localized: "Bypass Permissions isn’t turned on for this chat. Start a new chat with it turned on to use it.")
        case .unreadable:
            String(localized: "Couldn’t read the current mode from the screen. Try again, or check the terminal.")
        case .keysFailed:
            String(localized: "Couldn’t send the keys to the host. Try again, or check the terminal.")
        case .paneChanged:
            String(localized: "This pane is running a different chat now, so the mode wasn’t changed.")
        }
    }
}
