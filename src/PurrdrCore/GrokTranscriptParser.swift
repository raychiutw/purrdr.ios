import Foundation

/// Grok 對話紀錄(ACP `session/update` 通知的 JSONL)的解析器(行為規格 §4.3)。【未實測】
///
/// 位置：`${GROK_HOME:-$HOME/.grok}/sessions/<編碼後的 cwd>/<session id>/updates.jsonl`。一行一個通知,
/// Grok 會把每則訊息的 chunk 合併成一行:
///
/// ```json
/// {"timestamp":1792073586,"method":"session/update","params":{"sessionId":"…","update":{"sessionUpdate":"user_message_chunk",
///  "content":{"type":"text","text":"hi"},"_meta":{"modelId":"grok-5"}},"_meta":{"eventId":"ev-1","agentTimestampMs":1792073586001}}}
/// ```
///
/// 依 Grok 1.0.52 的行為描述撰寫，本機沒有 Grok 可以驗證。
public enum GrokTranscriptParser {
    public static func messages(in line: String) -> [TranscriptMessage] {
        guard let (params, update) = notification(line), let kind = update["sessionUpdate"] as? String else { return [] }
        let meta = params["_meta"] as? [String: Any]
        let id = (meta?["eventId"] as? String).flatMap { $0.isEmpty ? nil : "acp:" + $0 } ?? ClaudeTranscriptParser.stableID(of: line)
        let date = date(params: params, meta: meta, line: line)
        let message = { (role: TranscriptMessage.Role, parts: [TranscriptPart]) -> [TranscriptMessage] in
            parts.isEmpty ? [] : [TranscriptMessage(id: id, role: role, date: date, parts: parts)]
        }
        switch kind {
        case "user_message_chunk":
            // Grok 自己寫的 prompt(記憶、提醒)不是使用者打的。
            let updateMeta = update["_meta"] as? [String: Any]
            if updateMeta?["syntheticPrompt"] as? Bool == true || updateMeta?["hideFromScrollback"] as? Bool == true { return [] }
            return message(.user, userParts(update["content"]))
        case "agent_message_chunk":
            return message(.assistant, text(update["content"]).map { [.text($0)] } ?? [])
        case "agent_thought_chunk":
            return message(.assistant, text(update["content"]).map { [.thinking($0)] } ?? [])
        case "tool_call":
            let tool = (update["_meta"] as? [String: Any])?["x.ai/tool"] as? [String: Any]
            let name = (tool?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? update["title"] as? String ?? ""
            let input = update["rawInput"] as? [String: Any] ?? [:]
            return message(.assistant, [.toolCall(
                id: update["toolCallId"] as? String, name: name,
                input: ClaudeTranscriptParser.inputPreview(input), path: ClaudeTranscriptParser.filePath(in: input)
            )])
        case "tool_call_update":
            // 只有完成或失敗的那一筆是結果;之前的更新是進度。
            let status = update["status"] as? String
            guard status == "completed" || status == "failed" else { return [] }
            return message(.user, [.toolResult(
                callID: update["toolCallId"] as? String,
                text: resultText(update["content"]).truncated(to: 4000),
                isError: status == "failed"
            )])
        default:
            // turn 結束、計畫、模式、背景任務、記憶:忽略。
            return []
        }
    }

    /// 模型取任何 update 的 `_meta.modelId`;Grok 沒有 context 數。
    public static func updateMetadata(_ metadata: inout TranscriptMetadata, with line: String) {
        guard let (_, update) = notification(line),
              let model = (update["_meta"] as? [String: Any])?["modelId"] as? String, !model.isEmpty else { return }
        metadata.model = model
    }

    // MARK: - 內部

    private static func notification(_ line: String) -> ([String: Any], [String: Any])? {
        guard let object = ClaudeTranscriptParser.jsonObject(line),
              let method = object["method"] as? String, method == "session/update" || method == "_x.ai/session/update",
              let params = object["params"] as? [String: Any], let update = params["update"] as? [String: Any] else { return nil }
        return (params, update)
    }

    private static func date(params: [String: Any], meta: [String: Any]?, line: String) -> Date? {
        if let millis = (meta?["agentTimestampMs"] as? NSNumber)?.doubleValue, millis.isFinite, millis >= 0 {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        let object = ClaudeTranscriptParser.jsonObject(line)
        if let seconds = (object?["timestamp"] as? NSNumber)?.doubleValue, seconds.isFinite, seconds >= 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// content block 只有 `type:"text"` 帶文字。
    private static func text(_ content: Any?) -> String? {
        guard let block = content as? [String: Any], block["type"] as? String == "text",
              let text = block["text"] as? String, !text.isBlank else { return nil }
        return text
    }

    private static func userParts(_ content: Any?) -> [TranscriptPart] {
        if let block = content as? [String: Any], block["type"] as? String == "image" { return [.images(1)] }
        return text(content).map { [.text($0.trimmingCharacters(in: .whitespacesAndNewlines))] } ?? []
    }

    /// 結果文字：每個 `{type:"content"}` 的文字;`{type:"diff", path}` 顯示「Edited <path>」。
    private static func resultText(_ content: Any?) -> String {
        let items = content as? [[String: Any]] ?? []
        return items.compactMap { item -> String? in
            switch item["type"] as? String {
            case "content": text(item["content"])
            case "diff": (item["path"] as? String).map { "Edited \($0)" }
            default: nil
            }
        }.joined(separator: "\n")
    }
}
