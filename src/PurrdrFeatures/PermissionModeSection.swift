import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 標題面板下半的權限模式選項(#380,取代 #306 的輸入列膠囊與選擇 sheet):勾選列直接展開,選定就切換(同 DESIGN.md「選擇控制」)。
/// 清單依這個聊天實際可用的模式決定(#383):預設一般／接受編輯／規劃,看過略過權限或自動才加入;「不詢問」只在目前就是它時
/// 顯示,不能切過去。Agent 在等你回覆、唯讀裝置或離線時停用並說明原因(Shift+Tab 在等回覆時會變成「核准」);
/// 切換失敗留在這裡說明並有「再試一次」。
struct PermissionModeSection: View {
    let model: ConversationModel
    /// 切換成功後呼叫(sheet 據此自動關閉);失敗時不呼叫,留在畫面說明。
    var onSwitched: (() -> Void)?

    private var selection: Binding<AgentPermissionMode> {
        Binding(
            get: { model.switchingPermissionMode ?? model.permissionMode ?? .normal },
            set: { mode in
                guard mode.isSwitchable else { return }
                Task {
                    await model.setPermissionMode(mode)
                    if model.permissionMode == mode, model.permissionModeFailure == nil { onSwitched?() }
                }
            }
        )
    }

    var body: some View {
        Section {
            Picker(String(localized: "Permission Mode"), selection: selection) {
                ForEach(model.permissionModeOptions, id: \.self) { mode in
                    Text(verbatim: mode.displayName).tag(mode)
                        .disabled(!mode.isSwitchable)
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
        case .working: "The agent is working. Wait until it’s done to change the mode."
        }
    }
}

extension PermissionModeFailure {
    var text: String {
        switch self {
        case .notReached(let attempts, let target):
            String(localized: "Tried \(attempts) times, but the screen doesn’t show \(target.displayName) mode. Try again, or check the terminal.")
        case .modeUnavailable(let mode):
            if mode == .auto {
                String(localized: "Auto isn’t turned on for this chat, so it can’t be switched to here.")
            } else {
                String(localized: "Bypass Permissions isn’t turned on for this chat. Start a new chat with it turned on to use it.")
            }
        case .unreadable:
            String(localized: "Couldn’t read the current mode from the screen. Try again, or check the terminal.")
        case .keysFailed:
            String(localized: "Couldn’t send the keys to the host. Try again, or check the terminal.")
        case .paneChanged:
            String(localized: "This pane is running a different chat now, so the mode wasn’t changed.")
        }
    }
}

/// Codex 面板的核准政策(#383):只顯示、不能在手機切換。
struct ApprovalPolicySection: View {
    let policy: String

    var body: some View {
        Section {
            LabeledContent("Approval Policy") {
                Text(verbatim: Self.displayName(of: policy))
                    .foregroundStyle(.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("approvalPolicy.row")
        } footer: {
            Text("This is set on the host and can’t be changed here.")
        }
    }

    /// 已知的政策用好懂的名稱,不認得的照原文。
    static func displayName(of policy: String) -> String {
        switch policy {
        case "untrusted": String(localized: "Ask for Most Actions")
        case "on-request": String(localized: "Ask When Needed")
        case "on-failure": String(localized: "Ask After a Failure")
        case "never": String(localized: "Never Ask")
        default: policy
        }
    }
}
