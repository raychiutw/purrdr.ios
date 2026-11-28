import PurrdrCore
@preconcurrency import SwiftUI

/// 方案用量畫面上「依 Agent 而不同」的說明文字(#686、ADR-0013)。
///
/// 畫面與 model 不看種類分支:問 `AgentID.planUsageCopy`。文字的 key 就是原本寫在畫面裡的英文原文,
/// 只是集中在這一張表;新增 Agent 的用量來源時在這裡加一份。
/// Codex 沒有「改主機設定」的流程,同意與還原那幾條不會出現;沒有用量時的說明(`noData*`)維持沿用 Claude Code 的文字。
package struct PlanUsageCopy: Sendable {
    /// 用量條上的短名稱(「Claude · 5 小時」)。
    package var shortName: String
    package var consentTitle: LocalizedStringKey
    package var consentDetail: @Sendable (_ hostName: String) -> LocalizedStringKey
    package var consentAlertTitle: LocalizedStringKey
    package var turnOffTitle: LocalizedStringKey
    package var consentMessage: @Sendable (_ user: String) -> String
    package var installingTitle: LocalizedStringKey
    package var restoringTitle: LocalizedStringKey
    package var noDataTitle: LocalizedStringKey
    package var noDataDetail: @Sendable (_ hostName: String) -> LocalizedStringKey
    package var settingsChangedMessage: @Sendable () -> String
    package var unsafeToChangeMessage: @Sendable () -> String
    /// 圓環下方的說明:來源說明加上(有的話)最後回報的時間。
    package var footnote: @Sendable (_ asOf: Date?) -> Text

    package static let claude = PlanUsageCopy(
        shortName: "Claude",
        consentTitle: "Show Claude plan usage on this host?",
        consentDetail: { "Purrdr changes the Claude Code status line on \($0) so it saves plan usage. You can turn it off and restore the original anytime." },
        consentAlertTitle: "Show Claude Plan Usage?",
        turnOffTitle: "Turn Off Claude Plan Usage",
        consentMessage: { String(localized: "To show plan usage, Purrdr changes one Claude Code setting on this host (signed in as \($0)). Turning this off puts it back.") },
        installingTitle: "Changing the host’s Claude settings…",
        restoringTitle: "Restoring the host’s Claude settings…",
        noDataTitle: "Claude Code hasn’t reported plan usage yet",
        noDataDetail: { "Use Claude Code once on \($0), then pull down to refresh." },
        settingsChangedMessage: { String(localized: "Claude Code’s settings changed while Purrdr was updating them. Nothing was changed; try again.") },
        unsafeToChangeMessage: { String(localized: "Purrdr can’t safely change Claude Code’s settings on this host.") },
        footnote: { asOf in
            if let asOf {
                Text("As of \(asOf, format: .dateTime.hour().minute()), when Claude Code last reported on this host.")
            } else {
                Text("Claude Code reports these numbers while it runs on this host.")
            }
        })

    package static let codex: PlanUsageCopy = {
        var copy = claude
        copy.shortName = "Codex"
        copy.footnote = { asOf in
            if let asOf {
                Text("As of \(asOf, format: .dateTime.hour().minute()). Codex reports these numbers for the ChatGPT plan Codex is signed in with on this host.")
            } else {
                Text("Codex reports these numbers for the ChatGPT plan Codex is signed in with on this host.")
            }
        }
        return copy
    }()

    package static let antigravity = PlanUsageCopy(
        shortName: "Antigravity",
        consentTitle: "Show Antigravity plan usage on this host?",
        consentDetail: { "Purrdr changes the Antigravity status line on \($0) so it saves plan usage. You can turn it off and restore the original anytime." },
        consentAlertTitle: "Show Antigravity Plan Usage?",
        turnOffTitle: "Turn Off Antigravity Plan Usage",
        consentMessage: { String(localized: "To show plan usage, Purrdr changes one Antigravity setting on this host (signed in as \($0)). Turning this off puts it back.") },
        installingTitle: "Changing the host’s Antigravity settings…",
        restoringTitle: "Restoring the host’s Antigravity settings…",
        noDataTitle: "Antigravity hasn’t reported plan usage yet",
        noDataDetail: { "Use Antigravity once on \($0), then pull down to refresh." },
        settingsChangedMessage: { String(localized: "Antigravity’s settings changed while Purrdr was updating them. Nothing was changed; try again.") },
        unsafeToChangeMessage: { String(localized: "Purrdr can’t safely change Antigravity’s settings on this host.") },
        footnote: { asOf in
            if let asOf {
                Text("As of \(asOf, format: .dateTime.hour().minute()), when Antigravity last reported on this host.")
            } else {
                Text("Antigravity reports these numbers while it runs on this host.")
            }
        })
}

extension AgentID {
    /// 方案用量畫面的說明文字;沒有方案用量的種類沿用 Claude 那份(畫面不會顯示它們)。
    package var planUsageCopy: PlanUsageCopy {
        switch self {
        case .agy: .antigravity
        case .codex: .codex
        default: .claude
        }
    }
}
