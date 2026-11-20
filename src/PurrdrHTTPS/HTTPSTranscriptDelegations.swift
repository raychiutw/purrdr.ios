import Foundation
import PurrdrCore

/// HTTPS 的列表預覽與 subagent／workflow／委派讀取(#289)。主機服務只讀這條連線定位過的對話紀錄，
/// 所以預覽先定位、重新連線後主機不認得就重新定位再讀一次;回傳的格式與 SSH 腳本的輸出相同，`TranscriptReader` 照原樣解析。
extension HTTPSHostConnection {
    func previews(marker: String, requests: [PreviewRequest]) async throws -> Data {
        try await requireHostService(.transcriptPreviewsAndDelegations)
        do {
            return try await readPreviews(marker: marker, requests: requests)
        } catch TranscriptReadError.invalidReference {
            previewLocations = [:]
            return try await readPreviews(marker: marker, requests: requests)
        }
    }

    /// 每個請求印「標記 key」;讀得到的再印「標記@ key 範圍 版本」與行(Pi／Codex 的整段檔尾另印「標記! key」與 header)。
    private func readPreviews(marker: String, requests: [PreviewRequest]) async throws -> Data {
        var located: [(request: PreviewRequest, location: PreviewLocation)] = []
        for request in requests {
            if let location = try await previewLocation(of: request.target) { located.append((request, location)) }
        }
        var output = requests.map { "\(marker) \($0.key)\n" }.joined()
        guard !located.isEmpty else { return Data(output.utf8) }
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
            guard let location = located.first(where: { $0.request.key == preview.key })?.location else { continue }
            output += "\(marker)@ \(preview.key) \(preview.change.rawValue) \(preview.version)\n"
            if preview.change == .whole, let header = location.header {
                output += "\(marker)! \(preview.key)\n" + header.map { $0 + "\n" }.joined() + "\(marker) \(preview.key)\n"
            }
            // SSH 預覽腳本只印剝除圖片後的行，不帶原始長度。
            output += preview.records.map { $0.text + "\n" }.joined()
        }
        return Data(output.utf8)
    }

    /// 定位過的路徑;找不到或主機讀不了這種 agent 的對話紀錄時為 `nil`(不在預覽結果裡，同 SSH)。
    private func previewLocation(of target: TranscriptTarget) async throws -> PreviewLocation? {
        if let known = previewLocations[target.location] { return known }
        let readsHeader: Bool = switch target.location {
        case .codex: true
        default: target.format == .piJournal
        }
        do {
            let result = try await withDeadline(HostCommandDeadline.standard) {
                try await self.locateResult(Self.sessionReference(target.location), header: readsHeader)
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

    /// 兩行一組「meta 路徑」「meta 內容」,同 SSH 的找 subagent 腳本;主機服務已確認 `toolUseId` 完全相等。
    func findSubagent(sessionFolder: String, callID: String) async throws -> Data {
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
        let meta = try JSONSerialization.data(withJSONObject: ["toolUseId": callID])
        return Data("\(result.path.dropLast(".jsonl".count)).meta.json\n".utf8) + meta + Data("\n".utf8)
    }

    /// 「種類 checksum」一行，與已知的不同時再接檔案內容，同 SSH 的 workflow 腳本。
    func readWorkflow(sessionFolder: String, runID: String, knownChecksum: String) async throws -> Data {
        try await requireHostService(.transcriptPreviewsAndDelegations)
        let parent = sessionFolder + ".jsonl"
        // 已知的是「種類 checksum」,主機服務只比 checksum。
        let known = knownChecksum.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)
        let reply = try await readingLocated(parent) {
            try await self.send { .transcriptWorkflow(.init(requestId: $0, path: parent, runId: runID, knownChecksum: known)) }
        }
        guard case .transcriptWorkflowResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        let line = "\(result.kind.rawValue) \(result.checksum)"
        guard let content = result.content else {
            // 種類換了但 checksum 相同(不該發生):沒有內容可解析。
            guard line == knownChecksum else { throw TranscriptReadError.changed }
            return Data((line + "\n").utf8)
        }
        return Data((line + "\n" + content).utf8)
    }

    /// checksum 一行，與已知的不同時再接「原始長度 TAB 行」,同 SSH 的委派腳本。
    func delegationLines(path: String, callID: String, agentID: String, knownChecksum: String) async throws -> Data {
        try await requireHostService(.transcriptPreviewsAndDelegations)
        let known = knownChecksum.isEmpty ? nil : knownChecksum
        let reply = try await readingLocated(path) {
            try await self.send { .transcriptDelegation(.init(requestId: $0, path: path, callId: callID, agentId: agentID, knownChecksum: known)) }
        }
        guard case .transcriptDelegationResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return Data("\(result.checksum)\n".utf8) + Self.recordLines(result.records ?? [])
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
