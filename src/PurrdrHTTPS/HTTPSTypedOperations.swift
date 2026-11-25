import Foundation
import PurrdrCore

/// HTTPS 的型別化主機操作(ADR-0015、#594):直接對應主機服務協定訊息，不再先組成 herdr／SSH 腳本的位元組格式再解回。
/// 錯誤、期限與版本門檻與 `herdrRequest`／`readTranscript` 的路徑一致(同一組 `HostServiceError`、`TranscriptReadError`)。
extension HTTPSHostConnection {
    public func readSnapshot() async throws -> HostSnapshot {
        try await withDeadline(HostCommandDeadline.standard) {
            let welcome = try await self.hostServiceInfo()
            let reply = try await self.send(on: self.liveSession(), { .agentsList(.init(requestId: $0)) }, herdrMethod: "session.snapshot")
            guard case .agentsListResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
            return Self.snapshot(from: result, version: welcome.herdr.version)
        }
    }

    public func sendKeys(paneID: String, keys: [String], expecting: SendExpectation) async throws {
        let expectedSession = await checkedExpectation(expecting).session
        try await withDeadline(HostCommandDeadline.standard) {
            let reply = try await self.send(
                on: self.liveSession(),
                { .paneSendKeys(.init(requestId: $0, paneId: paneID, keys: keys, expectedSession: expectedSession)) },
                herdrMethod: "pane.send_keys")
            guard case .paneSendKeysResult = reply else { throw HostServiceError.unexpectedResponse }
        }
    }

    public func sendText(paneID: String, text: String, expecting: SendExpectation) async throws {
        let expectedSession = await checkedExpectation(expecting).session
        try await withDeadline(HostCommandDeadline.standard) {
            let reply = try await self.send(
                on: self.liveSession(),
                { .paneSendText(.init(requestId: $0, paneId: paneID, text: text, expectedSession: expectedSession)) },
                herdrMethod: "pane.send_text")
            guard case .paneSendTextResult = reply else { throw HostServiceError.unexpectedResponse }
        }
    }

    public func readPaneScreen(paneID: String, lines: Int, format: PaneReadFormat) async throws -> String {
        try await requireHostService(.paneRead)
        let wireFormat: HostServiceProtocol.PaneReadFormat? = format == .ansi ? .ansi : nil
        return try await withDeadline(HostCommandDeadline.standard) {
            let reply = try await self.send(
                on: self.liveSession(),
                { .paneRead(.init(requestId: $0, paneId: paneID, source: .visible, format: wireFormat, lines: lines)) },
                herdrMethod: "pane.read")
            guard case .paneReadResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
            return result.text
        }
    }

    public func locateTranscript(_ location: TranscriptLocation) async throws -> TranscriptFile {
        guard location.isSafe else { throw TranscriptReadError.invalidReference }
        let result = try await withDeadline(HostCommandDeadline.standard) {
            try await self.locateResult(location.sessionReference, header: location.locator.readsHeader)
        }
        return try TranscriptReader.locatedFile(lines: [result.path, String(result.size)] + (result.header ?? []), for: location)
    }

    public func readTranscriptWindow(path: String, end: Int, lines: Int, maxBytes: Int) async throws -> TranscriptChunk {
        guard TranscriptReader.isValidPath(path), end >= 0, lines > 0 else { throw TranscriptReadError.invalidReference }
        let installed = maxBytes > 0 ? ((try? await hostServiceVersion()) ?? nil) : nil
        let limit: Int? = HostServiceFeature.transcriptWindowMaxBytes.isAvailable(onHostServiceVersion: installed) ? maxBytes : nil
        let result = try await withDeadline(HostCommandDeadline.maximumRead) {
            let reply = try await self.send { .transcriptWindow(.init(requestId: $0, path: path, end: end, lines: lines, maxBytes: limit)) }
            guard case .transcriptWindowResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
            return result
        }
        guard result.start <= result.end, result.end <= end else { throw TranscriptReadError.changed }
        // 回應範圍與每行原始長度加總不合 → 讀取中檔案變了，重試(與 SSH 腳本輸出的檢查相同)。
        guard result.records.reduce(0, { $0 + $1.length + 1 }) == result.end - result.start else { throw TranscriptReadError.changed }
        return TranscriptChunk(start: result.start, end: result.end, lines: result.records.map(\.text))
    }

    // MARK: - 輔助

    /// 主機會比對時才帶比對欄位(與 `HerdrClient` 相同)。
    private func checkedExpectation(_ expectation: SendExpectation) async -> SendExpectation {
        guard !expectation.isEmpty, await checksSendExpectations() else { return .none }
        return expectation
    }

    static func snapshot(from result: HostServiceProtocol.AgentsListResult, version: String) -> HostSnapshot {
        func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        let labels = Dictionary(result.workspaces.map { ($0.workspaceId, $0.label) }, uniquingKeysWith: { first, _ in first })
        return HostSnapshot(
            version: version,
            workspaces: result.workspaces.map { Workspace(id: $0.workspaceId, number: 0, label: nonEmpty($0.label)) },
            agents: result.agents.map { agent in
                Agent(
                    paneID: agent.paneId, workspaceID: agent.workspaceId, kind: agent.agent ?? "",
                    status: AgentStatus(rawValue: agent.status.rawValue) ?? .unknown,
                    terminalTitle: nonEmpty(agent.title), workspaceLabel: nonEmpty(labels[agent.workspaceId]), cwd: nonEmpty(agent.cwd),
                    session: agent.session.map { AgentSessionReference(kind: $0.kind, value: $0.value) }, tabID: nonEmpty(agent.tabId))
            })
    }
}
