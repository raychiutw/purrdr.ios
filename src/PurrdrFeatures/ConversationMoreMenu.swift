import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 對話畫面右上角的整合「更多」選單(#381):Pane 終端機、Git 變更、顯示版面。
///
/// 系統 `Menu`(勾在前、圖示在後);Git 不可用時該項停用並在副標寫原因,選單不會只剩一項。
struct ConversationMoreMenu: View {
    let model: ConversationModel
    let canOpenTerminal: Bool
    let canShowLayout: Bool
    let openTerminal: () -> Void
    let openChanges: () -> Void
    let showLayout: () -> Void

    var body: some View {
        Menu {
            if canOpenTerminal {
                Button(action: openTerminal) {
                    item("Pane Terminal", subtitle: "This agent’s screen", systemImage: "apple.terminal")
                }
                .accessibilityIdentifier("terminal.open")
            }
            Button(action: openChanges) {
                item("Git Changes", subtitle: gitSubtitle, systemImage: "arrow.triangle.branch")
            }
            .disabled(!model.gitMenu.isEnabled || !model.canOpenChanges)
            .accessibilityIdentifier("changes.open")
            if canShowLayout {
                Button(action: showLayout) {
                    item("Show Layout", subtitle: "This tab’s pane layout", systemImage: "rectangle.split.2x2")
                }
                .accessibilityIdentifier("layout.show")
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .frame(minWidth: 44, minHeight: 44)    // 觸控範圍 ≥ 44pt
        .accessibilityIdentifier("conversation.more")
    }

    @ViewBuilder
    private func item(_ title: LocalizedStringKey, subtitle: LocalizedStringKey, systemImage: String) -> some View {
        // 系統選單的項目用「標題 Text、副標 Text、Image」三個子視圖排成標題＋副標＋圖示。
        Text(title)
        Text(subtitle)
        Image(systemName: systemImage)
    }

    /// 副標:可用時是「分支 · N 個檔案」,不可用時是原因。
    private var gitSubtitle: LocalizedStringKey {
        switch model.gitMenu {
        case .checking:
            model.canOpenChanges ? "This agent’s working folder" : "Folder unknown"
        case .available(let branch, let count):
            if let branch { "\(branch) · \(count) files" } else { "\(count) files" }
        case .unavailable(let reason):
            switch reason {
            case .unsupported: "Not available on this host"
            case .notGitRepository: "Not a Git folder"
            case .gitNotInstalled: "Git isn’t installed on the host"
            case .agentMoved: "The agent moved to another folder"
            case .hostServiceUpdateRequired: "Update the host service"
            }
        }
    }
}
