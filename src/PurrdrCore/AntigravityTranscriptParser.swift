import Foundation

/// Antigravity(`agy`)對話紀錄的解析器(行為規格 §4.4)。已用 agy 1.5.14 的真實錄製驗證(#446,
/// `Fixtures/other-agents/antigravity/live-1.5.14/`)。
///
/// 位置：`$HOME/.gemini/antigravity-cli/brain/<session id>/.system_generated/logs/transcript.jsonl`(或 herdr 回報的路徑)。
/// 一行一個 step:`{step_index, source, type, status, created_at, content, thinking?, tool_calls?, input_tokens?,
/// cache_read_tokens?, output_tokens?}`。旁邊的 `transcript_full.jsonl` 保留完整工具輸出，刻意不用。
///
/// 真實資料確認:`tool_calls[i]` 的參數在 `args`(仍容許 `arguments`),檔案路徑欄位是 `Path`(舊描述是 `AbsolutePath`);
/// 權限被拒的 `GENERIC` step 是 `status: "ERROR"` 並帶 `error` 欄位;`PLANNER_RESPONSE.model` 是 `gemini-4-neon-medium` 這種 id。
public enum AntigravityTranscriptParser {
    public static func messages(in line: String) -> [TranscriptMessage] {
        guard let step = step(line) else { return [] }
        let id = "agy:\(step.createdAt ?? ""):\(step.index)"
        let date = step.createdAt.flatMap(ClaudeTranscriptParser.parseDate)
        switch step.object["type"] as? String {
        case "USER_INPUT":
            // 只有 USER_EXPLICIT 是人打的;其他(設定變更等)不顯示。
            guard step.object["source"] as? String == "USER_EXPLICIT",
                  let text = userRequest(step.object["content"] as? String ?? ""), !text.isEmpty else { return [] }
            return [TranscriptMessage(id: id, role: .user, date: date, parts: [.text(text)])]
        case "PLANNER_RESPONSE":
            var parts: [TranscriptPart] = []
            if let thinking = step.object["thinking"] as? String, !thinking.isBlank { parts.append(.thinking(thinking)) }
            if let text = step.object["content"] as? String, !text.isBlank { parts.append(.text(text)) }
            for (index, call) in (step.object["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                let input = arguments(call)
                parts.append(.toolCall(
                    id: "agy-\(step.index):\(index)", name: call["name"] as? String ?? "",
                    input: ClaudeTranscriptParser.inputPreview(input), path: ClaudeTranscriptParser.filePath(in: input)
                ))
            }
            return parts.isEmpty ? [] : [TranscriptMessage(id: id, role: .assistant, date: date, parts: parts)]
        case "GENERIC":
            // 輸出配給**前一個 step** 的第一個呼叫，不依順序(R-I17)。
            // `status: "ERROR"` 時真正的原因在 `error` 欄位(`content` 裡是夾著時間行的同一段文字)。
            let failed = step.object["status"] as? String == "ERROR"
            let errorText = (step.object["error"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let text = failed && !(errorText ?? "").isEmpty ? errorText! : output(step.object["content"] as? String ?? "")
            return [TranscriptMessage(id: id, role: .user, date: date, parts: [
                .toolResult(callID: "agy-\(step.index - 1):0", text: text.truncated(to: 4000), isError: failed),
            ])]
        default:
            return []
        }
    }

    /// 模型與 effort:`PLANNER_RESPONSE` 的 `model` id(`gemini-4-neon-medium` → 「Gemini 4 Neon」、effort `medium`),
    /// 或任何 `USER_INPUT` 的「setting `Model Selection` from … to Gemini 4 Neon (Medium).」;較晚的覆蓋較早的。
    /// context = `input_tokens + cache_read_tokens`。
    public static func updateMetadata(_ metadata: inout TranscriptMetadata, with line: String) {
        guard let step = step(line) else { return }
        switch step.object["type"] as? String {
        case "USER_INPUT":
            let content = step.object["content"] as? String ?? ""
            if let match = content.firstMatch(of: /setting `Model Selection` from .*? to (.+?)\.(\s|$)/) {
                apply(modelLabel: String(match.output.1), to: &metadata)
            }
        case "PLANNER_RESPONSE":
            if let id = step.object["model"] as? String, !id.isEmpty { apply(modelID: id, to: &metadata) }
            let counts = ["input_tokens", "cache_read_tokens"].compactMap { step.object[$0] as? Int }
            if !counts.isEmpty, counts.reduce(0, +) > 0 { metadata.contextTokens = counts.reduce(0, +) }
        default:
            break
        }
    }

    // MARK: - 內部

    private static let efforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    /// 「Gemini 4 Neon (Medium)」→ 模型「Gemini 4 Neon」、effort `medium`;沒有括號就整段是模型(effort 沿用)。
    private static func apply(modelLabel label: String, to metadata: inout TranscriptMetadata) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if let match = trimmed.firstMatch(of: /^(.+?)\s*\((\w+)\)$/), efforts.contains(match.output.2.lowercased()) {
            metadata.model = String(match.output.1)
            metadata.effort = match.output.2.lowercased()
        } else {
            metadata.model = trimmed
        }
    }

    /// `gemini-4-neon-medium` → 「Gemini 4 Neon」、effort `medium`:最後一段是 effort 等級就拆出來,其餘各段首字大寫。
    private static func apply(modelID id: String, to metadata: inout TranscriptMetadata) {
        var parts = id.split(separator: "-").map(String.init)
        if let last = parts.last, efforts.contains(last.lowercased()), parts.count > 1 {
            metadata.effort = last.lowercased()
            parts.removeLast()
        }
        metadata.model = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private struct Step {
        var object: [String: Any]
        var index: Int
        var createdAt: String?
    }

    private static func step(_ line: String) -> Step? {
        guard let object = ClaudeTranscriptParser.jsonObject(line), let index = object["step_index"] as? Int,
              object["type"] is String, object["source"] is String else { return nil }
        return Step(object: object, index: index, createdAt: object["created_at"] as? String)
    }

    /// `<USER_REQUEST>` 與 `</USER_REQUEST>` 之間的文字;沒有標籤就是整段。
    private static func userRequest(_ content: String) -> String? {
        guard let open = content.range(of: "<USER_REQUEST>") else { return content.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let close = content.range(of: "</USER_REQUEST>", range: open.upperBound..<content.endIndex) else { return nil }
        return content[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 參數值是 JSON 字串，各自解析;去掉 `toolAction`;鍵改名成共通的名稱。
    private static func arguments(_ call: [String: Any]) -> [String: Any] {
        var raw = call["args"] ?? call["arguments"]
        if let text = raw as? String { raw = ClaudeTranscriptParser.jsonObject(text) }
        let renamed = ["CommandLine": "command", "Cwd": "cwd", "AbsolutePath": "file_path", "Path": "file_path", "toolSummary": "description"]
        var result: [String: Any] = [:]
        for (key, value) in raw as? [String: Any] ?? [:] where key != "toolAction" {
            var decoded = value
            if let text = value as? String, let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
                decoded = parsed
            }
            result[renamed[key] ?? key] = decoded
        }
        return result
    }

    /// 去掉開頭的 `Created At: …`／`Completed At: …` 行,CRLF 換成 LF。
    private static func output(_ content: String) -> String {
        var lines = content.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.hasPrefix("Created At: ") || first.hasPrefix("Completed At: ") {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
