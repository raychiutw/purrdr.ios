import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// Claude 權限模式膠囊(#306):輸入列工具列、附加鈕右邊。高度與底色跟附加鈕一樣,文字是一般文字色,
/// 只有「略過權限」用紅字。點一下切到下一個模式(像 Shift+Tab),長按開選單選模式;切換中顯示進行中。
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

    /// 切換中顯示目標模式。
    private var shown: AgentPermissionMode? { model.switchingPermissionMode ?? model.permissionMode }

    private var selection: Binding<AgentPermissionMode> {
        Binding(
            get: { shown ?? .normal },
            set: { mode in Task { await model.setPermissionMode(mode) } }
        )
    }

    var body: some View {
        Menu {
            Picker(String(localized: "Permission Mode"), selection: selection) {
                ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
                    Text(verbatim: Self.name(of: mode)).tag(mode)
                }
            }
            .pickerStyle(.inline)
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
        } primaryAction: {
            Task { await model.cyclePermissionMode() }
        }
        .composerSecondaryButtonStyle(isInCard: true)
        .buttonBorderShape(.capsule)
        .frame(minHeight: 44)
        .disabled(!model.canSwitchPermissionMode)
        .accessibilityLabel(Text("Permission Mode"))
        .accessibilityValue(Text(verbatim: shown.map(Self.name(of:)) ?? ""))
        .accessibilityHint(Text("Tap to switch to the next mode. Touch and hold to choose one."))
        .accessibilityIdentifier("composer.permissionMode")
    }
}
