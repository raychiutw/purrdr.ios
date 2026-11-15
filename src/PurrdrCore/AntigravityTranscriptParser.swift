import Foundation

/// Antigravity(`agy`)對話紀錄的解析器(行為規格 §4.4)。【未實測】
///
/// 位置：`$HOME/.gemini/antigravity-cli/brain/<session id>/.system_generated/logs/transcript.jsonl`(或 herdr 回報的路徑)。
/// 一行一個 step:`{step_index, source, type, status, created_at, content, thinking?, tool_calls?, input_tokens?,
/// cache_read_tokens?, output_tokens?}`。旁邊的 `transcript_full.jsonl` 保留完整工具輸出，刻意不用。
///
/// 依 agy 1.3.6 的行為描述撰寫，本機沒有 agy 可以驗證。`tool_calls[i]` 的參數欄位名(`args` 或 `arguments`)沒有
/// 公開文件，兩者都接受。
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
            let text = output(step.object["content"] as? String ?? "")
            return [TranscriptMessage(id: id, role: .user, date: date, parts: [
                .toolResult(callID: "agy-\(step.index - 1):0", text: text.truncated(to: 4000), isError: false),
            ])]
        default:
            return []
        }
    }

    /// 模型：任何 `USER_INPUT` 的「setting `Model Selection` from … to X.」;context = `input_tokens + cache_read_tokens`。
    public static func updateMetadata(_ metadata: inout TranscriptMetadata, with line: String) {
        guard let step = step(line) else { return }
        switch step.object["type"] as? String {
        case "USER_INPUT":
            let content = step.object["content"] as? String ?? ""
            if let match = content.firstMatch(of: /setting `Model Selection` from .*? to (.+?)\.(\s|$)/) {
                metadata.model = String(match.output.1)
            }
        case "PLANNER_RESPONSE":
            let counts = ["input_tokens", "cache_read_tokens"].compactMap { step.object[$0] as? Int }
            if !counts.isEmpty, counts.reduce(0, +) > 0 { metadata.contextTokens = counts.reduce(0, +) }
        default:
            break
        }
    }

    // MARK: - 內部

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
        let renamed = ["CommandLine": "command", "Cwd": "cwd", "AbsolutePath": "file_path", "toolSummary": "description"]
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
