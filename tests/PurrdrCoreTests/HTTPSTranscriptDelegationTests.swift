import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// HTTPS 的列表預覽與 subagent／workflow／委派讀取(#289):`TranscriptReader` 經主機服務讀到與 SSH 相同的結果。
@Suite("HTTPS 列表預覽與委派")
struct HTTPSTranscriptDelegationTests {
    static let sessionID = "00000000-0000-0000-0000-000000000001"
    static let sessionFolder = "/Users/demo/.claude/projects/-Users-demo-Projects-garden-journal/\(sessionID)"
    static let path = sessionFolder + ".jsonl"
    static let callID = "toolu_01A2b3C4d5E6f7G8h9"
    static let located = #"{"type":"transcript.locate.result","path":"\#(path)","size":48213}"#

    private static func start(
        _ replies: [String: String], queued: [String: [String]] = [:], hostServiceVersion: String = "0.7.0"
    ) async throws -> FakeHostService {
        try await FakeHostService.start(.init(transcriptReplies: replies, queuedTranscriptReplies: queued, hostServiceVersion: hostServiceVersion))
    }

    private static func reader(for service: FakeHostService) -> TranscriptReader {
        TranscriptReader(connection: HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" }))
    }

    private static let claudeRequest = PreviewRequest(key: "w1:p6", sessionID: sessionID, cwd: "/Users/demo/Projects/garden-journal")

    @Test("列表預覽：先定位，再以路徑讀檔尾;最後一則可讀訊息成為預覽，版本原樣帶回")
    func previewsLocateThenReadTail() async throws {
        let service = try await Self.start([
            "transcript.locate": Self.located,
            "transcript.previews": #"{"type":"transcript.previews.result","previews":[{"key":"w1:p6","change":"whole","version":"1795161012-48331 4e9a","records":[{"length":11,"text":"ge\":\"cut\"}}"},{"length":119,"text":"{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"標籤整理好了\"}]},\"uuid\":\"a2\"}"}]}]}"#,
        ])
        defer { Task { await service.stop() } }

        let readings = try await Self.reader(for: service).previewReadings(of: [Self.claudeRequest])

        let reading = try #require(readings["w1:p6"])
        #expect(reading.preview?.text == "標籤整理好了")
        #expect(reading.version == PreviewVersion("1795161012-48331 4e9a"))
        let sent = try #require(service.messages(ofType: "transcript.previews").first)
        let entries = try #require(sent["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries.first?["key"] as? String == "w1:p6")
        #expect(entries.first?["path"] as? String == Self.path)
        #expect(entries.first?["known_version"] == nil)
    }

    @Test("列表預覽：已定位過的聊天不再定位;已知版本原樣送出，沒變時沿用上次的預覽")
    func previewsReuseLocatedPathAndSendKnownVersion() async throws {
        let service = try await Self.start([
            "transcript.locate": Self.located,
            "transcript.previews": #"{"type":"transcript.previews.result","previews":[{"key":"w1:p6","change":"unchanged","version":"v1","records":[]}]}"#,
        ])
        defer { Task { await service.stop() } }
        let reader = Self.reader(for: service)
        var request = Self.claudeRequest
        request.knownVersion = PreviewVersion("v1")

        _ = try await reader.previewReadings(of: [request])
        let again = try #require(try await reader.previewReadings(of: [request])["w1:p6"])

        #expect(again.change == .unchanged)
        #expect(again.preview == nil)
        #expect(service.messages(ofType: "transcript.locate").count == 1)
        let entries = try #require(service.messages(ofType: "transcript.previews").last?["entries"] as? [[String: Any]])
        #expect(entries.first?["known_version"] as? String == "v1")
    }

    @Test("列表預覽：主機服務不認得路徑(重新連線後)就重新定位再讀一次")
    func previewsRelocateWhenPathNotAllowed() async throws {
        let service = try await Self.start(
            [
                "transcript.locate": Self.located,
                "transcript.previews": #"{"type":"transcript.previews.result","previews":[{"key":"w1:p6","change":"whole","version":"v2","records":[{"length":104,"text":"{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"好了\"}]},\"uuid\":\"a3\"}"}]}]}"#,
            ],
            queued: ["transcript.previews": [
                #"{"type":"transcript.previews.result","previews":[]}"#,
                #"{"type":"error","code":"transcript_not_allowed","message":"not located"}"#,
            ]])
        defer { Task { await service.stop() } }
        let reader = Self.reader(for: service)
        _ = try await reader.previewReadings(of: [Self.claudeRequest])

        let again = try await reader.previewReadings(of: [Self.claudeRequest])

        #expect(again["w1:p6"]?.preview?.text == "好了")
        #expect(service.messages(ofType: "transcript.locate").count >= 2)
    }

    @Test("列表預覽：找不到對話紀錄的聊天不送出、不在結果裡")
    func previewsSkipUnlocatedChats() async throws {
        let service = try await Self.start([
            "transcript.locate": #"{"type":"error","code":"transcript_absent","message":"no transcript"}"#,
        ])
        defer { Task { await service.stop() } }

        let readings = try await Self.reader(for: service).previewReadings(of: [Self.claudeRequest])

        #expect(readings["w1:p6"]?.preview == nil)
        #expect(service.messages(ofType: "transcript.previews").isEmpty)
    }

    @Test("主機服務 0.7.0 之前：不送出，丟需要更新主機服務")
    func olderHostServiceNeedsUpdate() async throws {
        let service = try await Self.start(["transcript.locate": Self.located], hostServiceVersion: "0.6.9")
        defer { Task { await service.stop() } }
        let reader = Self.reader(for: service)

        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.transcriptPreviewsAndDelegations, installedVersion: "0.6.9")) {
            _ = try await reader.previewReadings(of: [Self.claudeRequest])
        }
        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.transcriptPreviewsAndDelegations, installedVersion: "0.6.9")) {
            _ = try await reader.locateSubagent(sessionFolder: Self.sessionFolder, callID: Self.callID)
        }
        #expect(service.messages(ofType: "transcript.previews").isEmpty)
        #expect(service.messages(ofType: "transcript.subagent").isEmpty)
    }

    @Test("找 subagent:送父對話紀錄與呼叫 id,回傳主機服務找到的路徑")
    func subagentReturnsHostPath() async throws {
        let subagent = Self.sessionFolder + "/subagents/agent-a1b2c3d4.jsonl"
        let service = try await Self.start([
            "transcript.subagent": #"{"type":"transcript.subagent.result","path":"\#(subagent)"}"#,
        ])
        defer { Task { await service.stop() } }

        let found = try await Self.reader(for: service).locateSubagent(sessionFolder: Self.sessionFolder, callID: Self.callID)

        #expect(found == subagent)
        let sent = try #require(service.messages(ofType: "transcript.subagent").first)
        #expect(sent["path"] as? String == Self.path)
        #expect(sent["call_id"] as? String == Self.callID)
    }

    @Test("找 subagent:不只一個符合時與 SSH 相同當作改變了;還沒有時是 absent")
    func subagentAmbiguousIsChanged() async throws {
        let service = try await Self.start(
            ["transcript.subagent": #"{"type":"error","code":"transcript_absent","message":"none"}"#],
            queued: ["transcript.subagent": [#"{"type":"error","code":"transcript_ambiguous","message":"two"}"#]])
        defer { Task { await service.stop() } }
        let reader = Self.reader(for: service)

        await #expect(throws: TranscriptReadError.changed) {
            _ = try await reader.locateSubagent(sessionFolder: Self.sessionFolder, callID: Self.callID)
        }
        await #expect(throws: TranscriptReadError.absent) {
            _ = try await reader.locateSubagent(sessionFolder: Self.sessionFolder, callID: Self.callID)
        }
    }

    @Test("workflow:讀到 journal 的行;下次帶回 checksum,沒變時主機不回內容")
    func workflowJournalThenUnchanged() async throws {
        let service = try await Self.start(
            ["transcript.workflow": #"{"type":"transcript.workflow.result","kind":"journal","checksum":"c1"}"#],
            queued: ["transcript.workflow": [
                #"{"type":"transcript.workflow.result","kind":"journal","checksum":"c1","content":"{\"type\":\"workflow_started\",\"runId\":\"run_7f3a\"}\n{\"type\":\"agent_started\",\"agentId\":\"w1\"}\n"}"#,
            ]])
        defer { Task { await service.stop() } }
        let reader = Self.reader(for: service)

        let first = try await reader.readWorkflow(sessionFolder: Self.sessionFolder, runID: "run_7f3a", knownChecksum: nil)
        guard case .journal(let checksum, let lines) = first else {
            Issue.record("expected journal, got \(first)")
            return
        }
        let again = try await reader.readWorkflow(sessionFolder: Self.sessionFolder, runID: "run_7f3a", knownChecksum: checksum)

        #expect(lines == [#"{"type":"workflow_started","runId":"run_7f3a"}"#, #"{"type":"agent_started","agentId":"w1"}"#])
        #expect(again == .unchanged)
        let sent = service.messages(ofType: "transcript.workflow")
        #expect(sent.first?["path"] as? String == Self.path)
        #expect(sent.first?["run_id"] as? String == "run_7f3a")
        #expect(sent.first?["known_checksum"] == nil)
        #expect(sent.last?["known_checksum"] as? String == "c1")
    }

    @Test("workflow:結束後讀到 run 檔的原樣內容")
    func workflowRunFile() async throws {
        let service = try await Self.start([
            "transcript.workflow": #"{"type":"transcript.workflow.result","kind":"run","checksum":"c9","content":"{\"status\":\"completed\"}"}"#,
        ])
        defer { Task { await service.stop() } }

        let read = try await Self.reader(for: service).readWorkflow(sessionFolder: Self.sessionFolder, runID: "run_7f3a", knownChecksum: nil)

        guard case .run(_, let data) = read else {
            Issue.record("expected run, got \(read)")
            return
        }
        #expect(data == Data(#"{"status":"completed"}"#.utf8))
    }

    @Test("委派：父對話紀錄中指名呼叫與 agent 的行;checksum 相同時沒有行")
    func delegationLinesThenUnchanged() async throws {
        let service = try await Self.start(
            ["transcript.delegation": #"{"type":"transcript.delegation.result","checksum":"d1"}"#],
            queued: ["transcript.delegation": [
                #"{"type":"transcript.delegation.result","checksum":"d1","records":[{"length":131,"text":"{\"uuid\":\"a3\"}"},{"length":4210,"text":"{\"uuid\":\"u3\"}"}]}"#,
            ]])
        defer { Task { await service.stop() } }
        let reader = Self.reader(for: service)

        let first = try await reader.delegationLines(path: Self.path, callID: Self.callID, agentID: "a1b2c3d4", knownChecksum: nil)
        let again = try await reader.delegationLines(path: Self.path, callID: Self.callID, agentID: "a1b2c3d4", knownChecksum: first.checksum)

        #expect(first.checksum == "d1")
        #expect(first.lines == [#"{"uuid":"a3"}"#, #"{"uuid":"u3"}"#])
        #expect(again.lines == nil)
        let sent = service.messages(ofType: "transcript.delegation")
        #expect(sent.first?["path"] as? String == Self.path)
        #expect(sent.first?["call_id"] as? String == Self.callID)
        #expect(sent.first?["agent_id"] as? String == "a1b2c3d4")
        #expect(sent.last?["known_checksum"] as? String == "d1")
    }

    @Test("委派：主機服務不認得父對話紀錄(重新連線後)就以 session id 重新定位再讀")
    func delegationRelocatesWhenNotAllowed() async throws {
        let service = try await Self.start(
            [
                "transcript.locate": Self.located,
                "transcript.delegation": #"{"type":"transcript.delegation.result","checksum":"d2","records":[]}"#,
            ],
            queued: ["transcript.delegation": [#"{"type":"error","code":"transcript_not_allowed","message":"not located"}"#]])
        defer { Task { await service.stop() } }

        let result = try await Self.reader(for: service).delegationLines(path: Self.path, callID: Self.callID, agentID: nil, knownChecksum: nil)

        #expect(result.checksum == "d2")
        let locate = try #require(service.messages(ofType: "transcript.locate").first)
        #expect(locate["session"] as? [String: String] == ["kind": "id", "value": Self.sessionID])
        #expect(service.messages(ofType: "transcript.delegation").count == 2)
    }
}
