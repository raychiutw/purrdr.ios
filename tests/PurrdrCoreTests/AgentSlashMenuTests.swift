import Foundation
import PurrdrCore
import Testing

/// 各 agent 打 `/` 時的選單來源(行為規格 F9.1、#37 G17)。Grok、Antigravity 用固定清單(取自各自的官方文件,
/// 【未實測】);Pi／OMP 沒有選單;Claude 的清單由主機上發現(#15)。
@Suite("Slash 選單來源")
struct AgentSlashMenuTests {
    @Test("Grok 與 Antigravity 有各自的固定清單;Pi、OMP 沒有選單;Claude 由主機發現")
    func menuSourceByAgentKind() {
        #expect(AgentSlashMenu(agentKind: "pi") == .none)
        #expect(AgentSlashMenu(agentKind: "omp") == .none)
        #expect(AgentSlashMenu(agentKind: "amp") == .none)
        #expect(AgentSlashMenu(agentKind: "claude") == .discovered)
        guard case .fixed(let grok) = AgentSlashMenu(agentKind: "grok"), case .fixed(let agy) = AgentSlashMenu(agentKind: "agy") else {
            Issue.record("Grok／agy 沒有固定清單")
            return
        }
        #expect(grok.first { $0.name == "model" } == SlashCommand(name: "model", argumentHint: "<name>", summary: "Switch the active model"))
        #expect(grok.contains { $0.name == "compact" && $0.argumentHint == "[context]" })
        #expect(agy.contains { $0.name == "rewind" })
        #expect(agy.contains { $0.name == "voice" && $0.argumentHint == "[live|dictate]" })
        #expect(!agy.contains { $0.name == "compact-mode" })
    }

    /// 選單只在草稿是 `/` 加 `[\w:-]*` 時出現(F9.3),名稱必須符合同樣的字元;同一份清單不可重複。
    @Test("固定清單的名稱不重複，且只含選單比對用的字元")
    func fixedListsAreWellFormed() {
        for kind in ["grok", "agy", "codex"] {
            guard case .fixed(let commands) = AgentSlashMenu(agentKind: kind) else {
                Issue.record("\(kind) 沒有固定清單")
                continue
            }
            #expect(Set(commands.map(\.name)).count == commands.count, "\(kind) 有重複的指令")
            #expect(commands.allSatisfy { $0.name.wholeMatch(of: /[\w:-]+/) != nil && !$0.summary.isEmpty }, "\(kind) 有不合格的指令")
        }
    }

    /// G17(#37 故事 42):Codex 聊天打 `/` 時顯示 Codex 自己的指令。清單取自 openai/codex 公開原始碼
    /// (`codex-rs/tui/src/slash_command.rs`,2026-11-16 取用),【未實測】;只在 debug build 出現的不列。
    @Test("Codex 有自己的固定清單(內建指令);debug 專用的不列")
    func codexHasFixedList() {
        guard case .fixed(let codex) = AgentSlashMenu(agentKind: "codex") else {
            Issue.record("Codex 沒有固定清單")
            return
        }
        #expect(codex.first { $0.name == "model" } == SlashCommand(name: "model", summary: "Choose what model and reasoning effort to use"))
        for name in ["review", "compact", "status", "init", "new", "resume", "mention", "diff", "quit", "exit"] {
            #expect(codex.contains { $0.name == name }, "缺 /\(name)")
        }
        for name in ["rollout", "test-approval", "debug-m-drop", "debug-m-update"] {
            #expect(!codex.contains { $0.name == name }, "不該列 /\(name)")
        }
    }
}
