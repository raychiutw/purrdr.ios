import Foundation

/// Pi 與 OMP 共用的 session journal 解析器(行為規格 §4.5)。【未實測】
///
/// append-only JSONL,entry `{type, id, parentId, timestamp(ISO), …}`;第一行是 `{"type":"session","id":…}` header
/// (OMP 可能在它前面多一行固定寬度的 `{"type":"title",…}`)。`parentId` 構成分支樹，但這裡**依檔案順序**讀，不重建
/// 分支視圖。格式依 Pi 文件(`packages/coding-agent/docs/session-format.md`、`message-types.md`)與行為規格撰寫，
/// 本機沒有 Pi／OMP 可以驗證。
public enum PiJournalParser {
    public static func messages(in line: String) -> [TranscriptMessage] {
        guard let object = ClaudeTranscriptParser.jsonObject(line), let type = object["type"] as? String else { return [] }
        let entryID = object["id"] as? String
        let id = entryID.flatMap { $0.isEmpty ? nil : "omp:" + $0 } ?? ClaudeTranscriptParser.stableID(of: line)
        let entryDate = (object["timestamp"] as? String).flatMap(ClaudeTranscriptParser.parseDate)
        let note = { (text: String) in [TranscriptMessage(id: id, role: .system, date: entryDate, parts: [.note(text)])] }
        switch type {
        case "message":
            guard let message = object["message"] as? [String: Any] else { return [] }
            let date = messageDate(message) ?? entryDate
            let parts: [TranscriptPart]
            let role: TranscriptMessage.Role
            switch message["role"] as? String {
            case "user":
                role = .user
                parts = userParts(message["content"])
            case "assistant":
                role = .assistant
                parts = assistantParts(message["content"])
            case "toolResult":
                role = .user
                parts = [.toolResult(
                    callID: message["toolCallId"] as? String,
                    text: texts(in: message["content"]).joined(separator: "\n").truncated(to: 4000),
                    isError: message["isError"] as? Bool ?? false
                )]
            default:
                // system(prompt 與工具宣告)、bashExecution、custom…:不顯示。
                return []
            }
            return parts.isEmpty ? [] : [TranscriptMessage(id: id, role: role, date: date, parts: parts)]
        case "branch_summary":
            guard let summary = object["summary"] as? String, !summary.isBlank else { return [] }
            return note("Branch summary: " + summary.trimmingCharacters(in: .whitespacesAndNewlines))
        case "compaction":
            return note("Context compacted")
        case "reset_boundary":
            return note("Context reset")
        default:
            return []
        }
    }

    /// 模型取 assistant 的 `model`,或 `model_change` 的 `model ?? modelId`;effort 取 `thinking_level_change`;
    /// context 取 `contextSnapshot.promptTokens`,否則(輪次沒有中斷或出錯時)`usage.input + cacheRead + cacheWrite`。
    /// 中斷輪次的 usage 是 0,沒有意義，不更新(R-I18)。
    public static func updateMetadata(_ metadata: inout TranscriptMetadata, with line: String) {
        guard let object = ClaudeTranscriptParser.jsonObject(line) else { return }
        switch object["type"] as? String {
        case "model_change":
            if let model = nonEmpty(object["model"]) ?? nonEmpty(object["modelId"]) { metadata.model = model }
        case "thinking_level_change":
            if let level = object["thinkingLevel"] as? String, level.wholeMatch(of: /[a-z][a-z0-9_-]{0,31}/) != nil {
                metadata.effort = level
            }
        case "message":
            guard let message = object["message"] as? [String: Any], message["role"] as? String == "assistant" else { return }
            if let model = nonEmpty(message["model"]) { metadata.model = model }
            if let tokens = context(message: message, entry: object) { metadata.contextTokens = tokens }
        default:
            break
        }
    }

    /// 讀前檢查 header(行為規格 §4.5):檔案前兩行中，第一行可能是 OMP 的 `title`,接著必須是
    /// `{"type":"session","id":"<非空>"}`;`expectedID` 不是 `nil` 時必須相等。
    public static func headerMatches(_ lines: [String], expectedID: String?) -> Bool {
        var objects = lines.prefix(2).compactMap(ClaudeTranscriptParser.jsonObject)
        if objects.first?["type"] as? String == "title" { objects.removeFirst() }
        guard let header = objects.first, header["type"] as? String == "session",
              let id = header["id"] as? String, !id.isEmpty else { return false }
        return expectedID.map { $0 == id } ?? true
    }

    // MARK: - 內部

    private static func userParts(_ content: Any?) -> [TranscriptPart] {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(trimmed)]
        }
        let blocks = content as? [[String: Any]] ?? []
        var parts: [TranscriptPart] = []
        let text = texts(in: blocks).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append(.text(text)) }
        let images = blocks.filter { $0["type"] as? String == "image" }.count
        if images > 0 { parts.append(.images(images)) }
        return parts
    }

    private static func assistantParts(_ content: Any?) -> [TranscriptPart] {
        if let text = content as? String { return text.isBlank ? [] : [.text(text)] }
        var parts: [TranscriptPart] = []
        var images = 0
        for block in content as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isBlank { parts.append(.text(text)) }
            case "thinking":
                guard block["redacted"] as? Bool != true, let text = block["thinking"] as? String, !text.isBlank else { continue }
                parts.append(.thinking(text))
            case "toolCall":
                let input = block["arguments"] as? [String: Any] ?? [:]
                parts.append(.toolCall(
                    id: block["id"] as? String, name: block["name"] as? String ?? "",
                    input: ClaudeTranscriptParser.inputPreview(input), path: ClaudeTranscriptParser.filePath(in: input)
                ))
            case "image":
                images += 1
            default:
                // redactedThinking 與不認得的 block:略過。
                break
            }
        }
        if images > 0 { parts.append(.images(images)) }
        return parts
    }

    private static func texts(in content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        return (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    }

    /// `message.timestamp` 是毫秒;必須是有限的非負數。
    private static func messageDate(_ message: [String: Any]) -> Date? {
        guard let millis = (message["timestamp"] as? NSNumber)?.doubleValue, millis.isFinite, millis >= 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    private static func context(message: [String: Any], entry: [String: Any]) -> Int? {
        let snapshot = (message["contextSnapshot"] ?? entry["contextSnapshot"]) as? [String: Any]
        if let prompt = snapshot?["promptTokens"] as? Int, prompt > 0 { return prompt }
        let stop = message["stopReason"] as? String
        guard stop != "aborted", stop != "error", let usage = message["usage"] as? [String: Any] else { return nil }
        let counts = ["input", "cacheRead", "cacheWrite"].compactMap { usage[$0] as? Int }
        let total = counts.reduce(0, +)
        return counts.isEmpty || total <= 0 ? nil : total
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
