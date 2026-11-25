import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrTestSupport
import Testing

/// 型別化主機連線 2/3 第二批 C(#595):對話紀錄的追蹤讀取、預覽、subagent、workflow、委派經型別化操作。
@Suite("上層呼叫端改用型別化操作(對話紀錄)")
struct TypedTranscriptCallerMigrationTests {
    static let folder = "/Users/demo/.claude/projects/-Users-demo-p/00000000-0000-0000-0000-000000000001"
    static let path = folder + ".jsonl"

    @Test("TranscriptReader 的尾端讀取、預覽、subagent、workflow、委派都經連線的型別化操作")
    func transcriptReadsGoThroughTypedOperations() async throws {
        let connection = FakeHostConnection()
        await connection.stub(.transcriptTail, TranscriptTailRead(tail: .unchanged, size: 10))
        await connection.stub(.transcriptTail, TranscriptTailRead(tail: .unchanged, size: 10))
        await connection.stub(.transcriptPreviews, ["k": TranscriptPreviewBody(lines: [])])
        await connection.stub(.subagentLocate, Self.folder + "/subagents/agent-1.jsonl")
        await connection.stub(.workflow, WorkflowRead.run(checksum: "run abc", data: Data("{}".utf8)))
        await connection.stub(.delegation, DelegationRead(checksum: "sum", lines: []))
        let reader = TranscriptReader(connection: connection)
        let preview = PreviewRequest(key: "k", sessionID: "00000000-0000-0000-0000-000000000001", cwd: "/Users/demo/p")

        #expect(try await reader.tail(path: Self.path, from: 10) == .unchanged)
        #expect(try await reader.catchUp(path: Self.path, from: 10) == .unchanged)
        #expect(try await reader.previewReadings(of: [preview]).keys.contains("k"))
        #expect(try await reader.locateSubagent(sessionFolder: Self.folder, callID: "toolu_1") == Self.folder + "/subagents/agent-1.jsonl")
        #expect(
            try await reader.readWorkflow(sessionFolder: Self.folder, runID: "run_1", knownChecksum: nil)
                == .run(checksum: "run abc", data: Data("{}".utf8)))
        #expect(try await reader.delegationLines(path: Self.path, callID: "toolu_1", agentID: nil, knownChecksum: nil).checksum == "sum")

        #expect(await connection.typedCalls == [
            "readTranscriptTail \(Self.path) 10 65536 false", "readTranscriptTail \(Self.path) 10 262144 true", "readTranscriptPreviews k",
            "locateSubagent toolu_1", "readWorkflow run_1", "readDelegationLines toolu_1",
        ])
    }

    @Test("HTTPS 直接回型別化的委派與 workflow(checksum 相同沒有內容)")
    func httpsTypedDelegationAndWorkflow() async throws {
        let service = try await FakeHostService.start(.init(
            transcriptReplies: [
                "transcript.delegation": #"{"type":"transcript.delegation.result","checksum":"d1","records":[{"length":13,"text":"{\"uuid\":\"a3\"}"}]}"#,
                "transcript.workflow": #"{"type":"transcript.workflow.result","kind":"journal","checksum":"c1"}"#,
            ], hostServiceVersion: "0.7.0"))
        defer { Task { await service.stop() } }
        let connection = HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9")

        let delegation = try await connection.readDelegationLines(path: Self.path, callID: "toolu_1", agentID: "a1", knownChecksum: nil)
        let same = try await connection.readDelegationLines(path: Self.path, callID: "toolu_1", agentID: "a1", knownChecksum: "d1")
        let workflow = try await connection.readWorkflow(sessionFolder: Self.folder, runID: "run_1", knownChecksum: "journal c1")

        #expect(delegation == DelegationRead(checksum: "d1", lines: [#"{"uuid":"a3"}"#]))
        #expect(same == DelegationRead(checksum: "d1", lines: nil))
        #expect(workflow == .unchanged)
    }
}
