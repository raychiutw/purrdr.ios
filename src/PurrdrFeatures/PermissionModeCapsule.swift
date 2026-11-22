import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// Claude 權限模式膠囊(#306):輸入列工具列、附加鈕右邊。高度與底色跟附加鈕一樣,文字是一般文字色,
/// 只有「略過權限」用紅字。點一下開 sheet,裡面是勾選列選模式(同 DESIGN.md「選擇控制」);切換中顯示進行中。
struct PermissionModeCapsule: View {
    let model: ConversationModel

    static let height: Double = 34

    nonisolated static func name(of mode: AgentPermissionMode) -> String {
        switch mode {
        case .normal: String(localized: "Normal")
        case .acceptEdits: String(localized: "Accept Edits")
        case .plan: String(localized: "Plan")
        case .bypassPermissions: String(localized: "Bypass Permissions")
        }
    }

    @State private var isChoosing = false

    /// 切換中顯示目標模式。
    private var shown: AgentPermissionMode? { model.switchingPermissionMode ?? model.permissionMode }

    var body: some View {
        Button {
            isChoosing = true
        } label: {
            HStack(spacing: 6) {
                if model.isSwitchingPermissionMode {
                    ProgressView().controlSize(.mini)
                }
                Text(verbatim: shown.map(Self.name(of:)) ?? String(localized: "Permission Mode"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(shown == .bypassPermissions ? Color.red : Color.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.height)
        }
        .composerSecondaryButtonStyle(isInCard: true)
        .buttonBorderShape(.capsule)
        .frame(minHeight: 44)
        .disabled(!model.canSwitchPermissionMode)
        .accessibilityLabel(Text("Permission Mode"))
        .accessibilityValue(Text(verbatim: shown.map(Self.name(of:)) ?? ""))
        .accessibilityHint(Text("Opens the list of modes."))
        .accessibilityIdentifier("composer.permissionMode")
        .sheet(isPresented: $isChoosing) {
            PermissionModeSheet(model: model)
        }
    }
}

/// 權限模式的選擇 sheet:一般／接受編輯／Plan／略過權限的勾選列。選定後切換,成功就收起;
/// 失敗留在這裡說明原因並有「再試一次」(規格 #306)。
private struct PermissionModeSheet: View {
    let model: ConversationModel
    @Environment(\.dismiss) private var dismiss

    private var selection: Binding<AgentPermissionMode> {
        Binding(
            get: { model.switchingPermissionMode ?? model.permissionMode ?? .normal },
            set: { mode in
                Task {
                    await model.setPermissionMode(mode)
                    if model.permissionModeFailure == nil { dismiss() }
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(String(localized: "Permission Mode"), selection: selection) {
                        ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
                            Text(verbatim: PermissionModeCapsule.name(of: mode)).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(model.isSwitchingPermissionMode)
                    .accessibilityIdentifier("permissionMode.picker")
                }
                if let failure = model.permissionModeFailure {
                    Section {
                        Label(failure.text, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .accessibilityIdentifier("permissionMode.failure")
                        if failure.target != nil {
                            Button("Try Again") {
                                Task {
                                    await model.retryPermissionMode()
                                    if model.permissionModeFailure == nil { dismiss() }
                                }
                            }
                            .disabled(model.isSwitchingPermissionMode)
                            .accessibilityIdentifier("permissionMode.retry")
                        }
                    }
                }
            }
            .navigationTitle("Permission Mode")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("permissionMode.done")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

extension PermissionModeFailure {
    var text: String {
        switch self {
        case .notReached(let attempts, let target):
            String(localized: "Tried \(attempts) times, but the screen doesn’t show \(PermissionModeCapsule.name(of: target)) mode. Try again, or check the terminal.")
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
