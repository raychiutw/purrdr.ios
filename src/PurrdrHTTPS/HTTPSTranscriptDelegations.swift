import Foundation
import PurrdrCore

/// HTTPS 的列表預覽與 subagent／workflow／委派讀取(#289)。主機服務只讀這條連線定位過的對話紀錄，
/// 所以預覽先定位、重新連線後主機不認得就重新定位再讀一次。
extension HTTPSHostConnection {
    /// 預覽讀取:每個聊天的原始內容。
    func previewBodies(_ requests: [PreviewRequest]) async throws -> [String: TranscriptPreviewBody] {
        try await requireHostService(.transcriptPreviewsAndDelegations)
        do {
            return try await readPreviews(requests)
        } catch TranscriptReadError.invalidReference {
            previewLocations = [:]
            return try await readPreviews(requests)
        }
    }

    /// 每個請求都有一筆(沒讀到的是空內容,同 SSH 預覽腳本只印「標記 key」);讀得到的帶範圍與版本(Pi／Codex 的整段檔尾另帶 header)。
    private func readPreviews(_ requests: [PreviewRequest]) async throws -> [String: TranscriptPreviewBody] {
        var located: [(request: PreviewRequest, location: PreviewLocation)] = []
        for request in requests {
            if let location = try await previewLocation(of: request.target) { located.append((request, location)) }
        }
        var bodies = Dictionary(requests.map { ($0.key, TranscriptPreviewBody(lines: [])) }, uniquingKeysWith: { first, _ in first })
        guard !located.isEmpty else { return bodies }
        let entries = located.map {
            HostServiceProtocol.TranscriptPreviewEntry(key: $0.request.key, path: $0.location.path, knownVersion: $0.request.knownVersion?.value)
        }
        let reply = try await withDeadline(HostCommandDeadline.transfer(bytes: entries.count * TranscriptCommand.previewBytes)) {
            try await self.send { .transcriptPreviews(.init(requestId: $0, entries: entries)) }
        }
        guard case .transcriptPreviewsResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        let readKeys = Set(result.previews.map(\.key))
        for (request, _) in located where !readKeys.contains(request.key) {
            // 讀不到(換檔、刪除):下次重新定位。
            previewLocations[request.target.location] = nil
        }
        for preview in result.previews {
            guard let location = located.first(where: { $0.request.key == preview.key })?.location,
                  let change = PreviewReading.Change(rawValue: preview.change.rawValue) else { continue }
            // SSH 預覽腳本只印剝除圖片後的行，不帶原始長度。
            bodies[preview.key] = TranscriptPreviewBody(
                lines: preview.records.map(\.text), header: change == .whole ? location.header : nil,
                change: change, version: PreviewVersion(preview.version))
        }
        return bodies
    }

    /// 定位過的路徑;找不到或主機讀不了這種 agent 的對話紀錄時為 `nil`(不在預覽結果裡，同 SSH)。
    private func previewLocation(of target: TranscriptTarget) async throws -> PreviewLocation? {
        if let known = previewLocations[target.location] { return known }
        let readsHeader = target.location.locator.readsHeader
        do {
            let result = try await withDeadline(HostCommandDeadline.standard) {
                try await self.locateResult(target.location.sessionReference, header: readsHeader)
            }
            let location = PreviewLocation(path: result.path, header: readsHeader ? result.header ?? [] : nil)
            previewLocations[target.location] = location
            return location
        } catch is TranscriptReadError {
            return nil
        } catch HostServiceError.unsupported {
            return nil
        }
    }

    /// subagent 的對話紀錄路徑(主機服務已確認 `toolUseId` 完全相等)。
    func subagentPath(sessionFolder: String, callID: String) async throws -> String {
        try await requireHostService(.transcriptPreviewsAndDelegations)
        let parent = sessionFolder + ".jsonl"
        let reply: HostServiceProtocol.ServerMessage
        do {
            reply = try await readingLocated(parent) {
                try await self.send { .transcriptSubagent(.init(requestId: $0, path: parent, callId: callID)) }
            }
        } catch TranscriptReadError.ambiguous {
            throw TranscriptReadError.changed
        }
        guard case .transcriptSubagentResult(let result) = reply, result.path.hasSuffix(".jsonl") else {
            throw HostServiceError.unexpectedResponse
        }
        return result.path
    }

    /// workflow 進度讀取:「種類 checksum」與已知的相同時沒有內容。
    func workflow(sessionFolder: String, runID: String, knownChecksum: String?) async throws -> WorkflowRead {
        let result = try await workflowResult(sessionFolder: sessionFolder, runID: runID, knownChecksum: knownChecksum ?? "")
        let checksum = "\(result.kind.rawValue) \(result.checksum)"
        if checksum == knownChecksum { return .unchanged }
        guard let content = result.content else { throw TranscriptReadError.changed }
        if checksum.hasPrefix("run ") { return .run(checksum: checksum, data: Data(content.utf8)) }
        guard checksum.hasPrefix("journal ") else { throw TranscriptReadError.changed }
        return .journal(checksum: checksum, lines: content.split(separator: "\n").map(String.init))
    }

    private func workflowResult(
        sessionFolder: String, runID: String, knownChecksum: String
    ) async throws -> HostServiceProtocol.TranscriptWorkflowResult {
        try await requireHostService(.transcriptPreviewsAndDelegations)
        let parent = sessionFolder + ".jsonl"
        // 已知的是「種類 checksum」,主機服務只比 checksum。
        let known = knownChecksum.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)
        let reply = try await readingLocated(parent) {
            try await self.send { .transcriptWorkflow(.init(requestId: $0, path: parent, runId: runID, knownChecksum: known)) }
        }
        guard case .transcriptWorkflowResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return result
    }

    /// 委派讀取:checksum 與已知的相同時沒有行。
    func delegation(path: String, callID: String, agentID: String, knownChecksum: String?) async throws -> DelegationRead {
        let result = try await delegationResult(path: path, callID: callID, agentID: agentID, knownChecksum: knownChecksum ?? "")
        if result.checksum == knownChecksum { return DelegationRead(checksum: result.checksum, lines: nil) }
        return DelegationRead(checksum: result.checksum, lines: (result.records ?? []).map(\.text))
    }

    private func delegationResult(
        path: String, callID: String, agentID: String, knownChecksum: String
    ) async throws -> HostServiceProtocol.TranscriptDelegationResult {
        try await requireHostService(.transcriptPreviewsAndDelegations)
        let known = knownChecksum.isEmpty ? nil : knownChecksum
        let reply = try await readingLocated(path) {
            try await self.send { .transcriptDelegation(.init(requestId: $0, path: path, callId: callID, agentId: agentID, knownChecksum: known)) }
        }
        guard case .transcriptDelegationResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return result
    }

    /// 主機服務不認得這個對話紀錄(重新連線後還沒定位)時，以 session 資料夾名(Claude 的 session id)定位一次再讀。
    private func readingLocated(
        _ transcript: String, _ read: @escaping @Sendable () async throws -> HostServiceProtocol.ServerMessage
    ) async throws -> HostServiceProtocol.ServerMessage {
        do {
            return try await withDeadline(HostCommandDeadline.standard, read)
        } catch TranscriptReadError.invalidReference {
            let sessionFolder = ClaudeTranscript.sessionFolder(ofTranscript: transcript)
            guard let sessionID = HostPathSyntax.lastComponent(sessionFolder).map(String.init),
                  ClaudeTranscript.isSafeSessionID(sessionID) else { throw TranscriptReadError.invalidReference }
            let located = try await withDeadline(HostCommandDeadline.standard) {
                try await self.locateResult(.init(kind: "id", value: sessionID), header: false)
            }
            guard located.path == sessionFolder + ".jsonl" else { throw TranscriptReadError.invalidReference }
            return try await withDeadline(HostCommandDeadline.standard, read)
        }
    }
}

/// 列表預覽定位到的對話紀錄;`header` 只有要檢查 header 的格式(Pi／Codex)有。
struct PreviewLocation: Sendable {
    let path: String
    let header: [String]?
}
