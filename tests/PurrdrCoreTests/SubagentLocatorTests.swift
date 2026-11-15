import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 找出某個呼叫啟動的 subagent 檔(行為規格 §4.6、F10「Subagent 畫面」、R-W02)。
///
/// 腳本在本機對真實檔案執行(`LocalShellHost`)。meta 檔取自作者 Mac 上真實 subagent 資料夾、去識別化
/// (`Fixtures/claude-code/subagents/`)。
@Suite("Subagent 檔定位")
struct SubagentLocatorTests {
    static let sessionRelative = ".claude/projects/-Users-demo-Projects-ledger/00000000-0000-0000-0000-000000000002"
    static let background = "agent-ad3e0000000000001"
    static let foreground = "agent-ad3e0000000000004"

    /// 主機上放好兩個真實 meta(背景、前景各一)。
    static func host() throws -> (LocalShellHost, String) {
        let shell = try LocalShellHost.temporary()
        for name in [background, foreground] {
            try shell.write(Fixtures.subagentFile(name + ".meta.json"), to: "\(sessionRelative)/subagents/\(name).meta.json")
        }
        try shell.write(Fixtures.subagentFile(background + ".jsonl"), to: "\(sessionRelative)/subagents/\(background).jsonl")
        return (shell, shell.home.appending(path: sessionRelative).path(percentEncoded: false))
    }

    @Test("依 meta 的 toolUseId 找到這個呼叫的 subagent 對話紀錄")
    func findsByCallID() async throws {
        let (shell, folder) = try Self.host()
        let reader = TranscriptReader(channel: shell)

        let found = try await reader.locateSubagent(sessionFolder: folder, callID: "toolu_demo_d01")
        #expect(found == "\(folder)/subagents/\(Self.background).jsonl")
        let other = try await reader.locateSubagent(sessionFolder: folder, callID: "toolu_demo_d02")
        #expect(other == "\(folder)/subagents/\(Self.foreground).jsonl")
    }

    /// R-W02:兩個 agent 可在同一毫秒啟動，最新的檔不一定是這個呼叫的。
    @Test("絕不用最新檔：之後才寫入、id 只多一個字的另一個 agent 不會被當成這個呼叫的")
    func neverNewestFile() async throws {
        let (shell, folder) = try Self.host()
        // 以背景 agent 的真實 meta 為底：另一個呼叫(toolUseId 是 `toolu_demo_d01` 再加一個字)、晚一秒寫入。
        let meta = String(decoding: Fixtures.subagentFile(Self.background + ".meta.json"), as: UTF8.self)
            .replacingOccurrences(of: "\"toolu_demo_d01\"", with: "\"toolu_demo_d01b\"")
        try await Task.sleep(for: .milliseconds(1100))
        try shell.write(Data(meta.utf8), to: "\(Self.sessionRelative)/subagents/agent-ad3e00000000000b1.meta.json")

        let found = try await TranscriptReader(channel: shell).locateSubagent(sessionFolder: folder, callID: "toolu_demo_d01")

        #expect(found == "\(folder)/subagents/\(Self.background).jsonl")
    }

    @Test("沒有 subagents 資料夾或沒有對應的 meta 是「缺席」(啟動中，稍後再找)")
    func missingIsAbsent() async throws {
        let (shell, folder) = try Self.host()
        let reader = TranscriptReader(channel: shell)

        await #expect(throws: TranscriptReadError.absent) {
            try await reader.locateSubagent(sessionFolder: folder, callID: "toolu_demo_d99")
        }
        await #expect(throws: TranscriptReadError.absent) {
            try await reader.locateSubagent(sessionFolder: shell.home.appending(path: ".claude/projects/x/none").path(percentEncoded: false), callID: "toolu_demo_d01")
        }
    }

    @Test("id 不是安全字元就拒絕，不執行任何指令(§4.0)", arguments: ["toolu_demo d01", "toolu/../x", "", String(repeating: "a", count: 129), "x'y"])
    func unsafeIDRejected(id: String) async throws {
        let host = FakeHost()
        await #expect(throws: TranscriptReadError.invalidReference) {
            try await TranscriptReader(channel: host).locateSubagent(sessionFolder: "/Users/demo/.claude/projects/p/s", callID: id)
        }
        #expect(await host.executions.isEmpty)
    }

    @Test("session 資料夾：對話紀錄去掉 .jsonl;subagent 對話紀錄取 /subagents/ 之前的部分(subagent 的 subagent 平放在同一個主 session 下)")
    func sessionFolderOfTranscript() {
        #expect(ClaudeTranscript.sessionFolder(ofTranscript: "/Users/demo/.claude/projects/p/s1.jsonl") == "/Users/demo/.claude/projects/p/s1")
        #expect(ClaudeTranscript.sessionFolder(ofTranscript: "/Users/demo/.claude/projects/p/s1/subagents/agent-a1.jsonl") == "/Users/demo/.claude/projects/p/s1")
        #expect(ClaudeTranscript.sessionFolder(ofTranscript: "/Users/demo/.claude/projects/p/s1/subagents/workflows/wf_1/agent-a2.jsonl") == "/Users/demo/.claude/projects/p/s1")
    }

    @Test("workflow 裡 agent 的對話紀錄路徑:<session>/subagents/workflows/<runId>/agent-<id>.jsonl;id 不安全就沒有")
    func workflowAgentPath() {
        #expect(ClaudeTranscript.workflowAgentTranscript(sessionFolder: "/s", runID: "wf_1", agentID: "a2") == "/s/subagents/workflows/wf_1/agent-a2.jsonl")
        #expect(ClaudeTranscript.workflowAgentTranscript(sessionFolder: "/s", runID: "../wf", agentID: "a2") == nil)
    }

    /// R-W04:開著的 subagent 畫面自己在父對話紀錄裡找結束;內容沒變時主機只回一行 checksum。
    @Test("委派的行：父對話紀錄中含呼叫 id 或 agent id 的行;checksum 沒變不傳內容")
    func delegationLinesWithChecksum() async throws {
        let shell = try LocalShellHost.temporary()
        let lines = Fixtures.transcriptLines("delegation.jsonl")
        let path = ".claude/projects/-Users-demo-Projects-ledger/00000000-0000-0000-0000-000000000002.jsonl"
        try shell.write(Data((lines[0...1].joined(separator: "\n") + "\n" + lines[3] + "\n").utf8), to: path)
        let full = shell.home.appending(path: path).path(percentEncoded: false)
        let reader = TranscriptReader(channel: shell)

        let first = try await reader.delegationLines(path: full, callID: "toolu_demo_d01", agentID: "ad3e0000000000001", knownChecksum: nil)
        #expect(first.lines == Array(lines[0...1]))

        let same = try await reader.delegationLines(path: full, callID: "toolu_demo_d01", agentID: "ad3e0000000000001", knownChecksum: first.checksum)
        #expect(same.lines == nil)

        // 只有 task id(agent id)、沒有呼叫 id 的通知也算(第 7 行)。
        try shell.append(Data((lines[7] + "\n").utf8), to: path)
        let next = try await reader.delegationLines(path: full, callID: "toolu_demo_d01", agentID: "ad3e0000000000001", knownChecksum: first.checksum)
        #expect(next.lines == [lines[0], lines[1], lines[7]])
    }
}
