import Foundation

/// Codex rollout(`rollout-<時間>-<session id>.jsonl`)的解析器(行為規格 §4.2)。【未實測】
///
/// 一行一個 `{timestamp, type, payload}`;type 有 `session_meta`、`response_item`、`event_msg`、`turn_context`、
/// `compacted`。**只有 `response_item` 成為泡泡**:`event_msg` 是同一輪的重複，只取 `token_count` 當 header
/// 中繼資料(R-I16)。
///
/// 依行為規格(herdrchat 對 Codex 0.157–0.163 的行為描述)與 openai/codex 公開原始碼撰寫，本機沒有 Codex 可以驗證。
public enum CodexTranscriptParser {
    public static func messages(in line: String) -> [TranscriptMessage] {
        guard let object = ClaudeTranscriptParser.jsonObject(line), let payload = object["payload"] as? [String: Any],
              let kind = payload["type"] as? String else { return [] }
        let timestamp = object["timestamp"] as? String ?? ""
        // 跨視窗穩定，也區分稍後重複的相同 prompt(時間不同)。
        let id = "codex:\(timestamp):" + ClaudeTranscriptParser.stableID(of: line).dropFirst("line-".count)
        let date = ClaudeTranscriptParser.parseDate(timestamp)
        let message = { (role: TranscriptMessage.Role, parts: [TranscriptPart]) -> [TranscriptMessage] in
            parts.isEmpty ? [] : [TranscriptMessage(id: id, role: role, date: date, parts: parts)]
        }
        // `event_msg` 只取圖片生成結束的 `saved_path`(#225;欄位依原始碼 `ImageGenerationEndEvent`,未實測)。
        if object["type"] as? String == "event_msg" {
            guard kind == "image_generation_end", let image = generatedImage(payload) else { return [] }
            return message(.assistant, [.agentFile(image)])
        }
        guard object["type"] as? String == "response_item" else { return [] }
        switch kind {
        case "message":
            // 0.157 以前的 analysis channel 是內部推理;developer、system 等角色不是對話。
            guard payload["channel"] as? String != "analysis" else { return [] }
            switch payload["role"] as? String {
            case "user": return message(.user, userParts(payload["content"]))
            case "assistant": return message(.assistant, texts(payload["content"]).compactMap(assistantText).map(TranscriptPart.text))
            default: return []
            }
        case "agent_message":
            // 0.155 起 agent 對 agent 的訊息：sidechain 的「作者 → 收件者:文字」。欄位名依原始碼，未實測。
            let text = texts(payload["content"]).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let author = payload["author"] as? String ?? "agent"
            let recipient = payload["recipient"] as? String ?? "agent"
            return [TranscriptMessage(id: id, role: .assistant, date: date, isSidechain: true, parts: [.text("\(author) → \(recipient): \(text)")])]
        case "function_call", "custom_tool_call":
            let name = payload["name"] as? String ?? ""
            let input = toolInput(payload["arguments"] ?? payload["input"])
            return message(.assistant, [.toolCall(id: payload["call_id"] as? String, name: name,
                                                  input: input.preview, path: input.path)])
        case "local_shell_call":
            let command = ((payload["action"] as? [String: Any])?["command"] as? [String])?.joined(separator: " ") ?? ""
            return message(.assistant, [.toolCall(id: payload["call_id"] as? String, name: "local_shell", input: command.truncated(to: 2000), path: nil)])
        case "web_search_call":
            let query = (payload["action"] as? [String: Any])?["query"] as? String ?? ""
            return message(.assistant, [.toolCall(id: payload["call_id"] as? String ?? payload["id"] as? String, name: "web_search",
                                                  input: query.truncated(to: 2000), path: nil)])
        case "tool_search_call":
            let input = toolInput(payload["arguments"] ?? payload["query"])
            return message(.assistant, [.toolCall(id: payload["call_id"] as? String, name: "tool_search", input: input.preview, path: nil)])
        case "tool_search_output":
            let count = (payload["tools"] as? [Any])?.count ?? 0
            let failed = payload["status"] as? String == "failed"
            return message(.user, [.toolResult(callID: payload["call_id"] as? String,
                                               text: failed ? "Tool search failed" : "Found \(count) tools", isError: failed)])
        case "image_generation_call":
            let prompt = payload["revised_prompt"] as? String ?? ""
            let call = TranscriptPart.toolCall(id: payload["id"] as? String, name: "image_generation", input: prompt.truncated(to: 2000), path: nil)
            return message(.assistant, [call] + (generatedImage(payload).map { [.agentFile($0)] } ?? []))
        case "function_call_output", "custom_tool_call_output":
            let text = outputText(payload["output"])
            return message(.user, [.toolResult(callID: payload["call_id"] as? String, text: text.truncated(to: 4000), isError: isError(text))])
        case "reasoning":
            // 只取摘要;加密內容永不還原。
            let summary = (payload["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return message(.assistant, summary.isEmpty ? [] : [.thinking(summary)])
        default:
            return []
        }
    }

    /// 圖片生成的 `saved_path`(新格式可能是 `savedPath`)→ 產生圖片的檔案參照。
    private static func generatedImage(_ payload: [String: Any]) -> AgentFileReference? {
        guard let path = (payload["saved_path"] ?? payload["savedPath"]) as? String, HostPathSyntax.isAbsolute(path) else { return nil }
        return AgentFileReference(origin: .generatedImage, path: path)
    }

    /// 模型與 effort 取 `turn_context`;context 取 `event_msg` 的 `token_count.info.last_token_usage.input_tokens`
    /// (cached tokens 已包含在內，不可再加)。
    public static func updateMetadata(_ metadata: inout TranscriptMetadata, with line: String) {
        guard let object = ClaudeTranscriptParser.jsonObject(line), let payload = object["payload"] as? [String: Any] else { return }
        switch object["type"] as? String {
        case "turn_context":
            if let model = payload["model"] as? String, !model.isEmpty { metadata.model = model }
            if let effort = payload["effort"] as? String, effort.wholeMatch(of: /[a-z]{1,16}/) != nil { metadata.effort = effort }
        case "event_msg":
            guard payload["type"] as? String == "token_count",
                  let usage = (payload["info"] as? [String: Any])?["last_token_usage"] as? [String: Any],
                  let input = usage["input_tokens"] as? Int, input > 0 else { return }
            metadata.contextTokens = input
        default:
            break
        }
    }

    /// 檔案第一行必須是 `{"type":"session_meta","payload":{"id":"<id>",…}}`(§4.2 驗證)。
    public static func headerMatches(_ line: String, expectedID: String) -> Bool {
        guard let object = ClaudeTranscriptParser.jsonObject(line), object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else { return false }
        return payload["id"] as? String == expectedID
    }

    // MARK: - 內容

    /// content block 的文字：`input_text`、`output_text`、`text`、`summary_text`。
    private static func texts(_ content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        return (content as? [[String: Any]] ?? []).compactMap { block in
            switch block["type"] as? String {
            case "input_text", "output_text", "text", "summary_text": block["text"] as? String
            default: nil
            }
        }
    }

    private static func userParts(_ content: Any?) -> [TranscriptPart] {
        let images = (content as? [[String: Any]] ?? []).filter { $0["type"] as? String == "input_image" }.count
        let text = texts(content).compactMap(userText).joined(separator: "\n\n")
        var parts: [TranscriptPart] = text.isEmpty ? [] : [.text(text)]
        if images > 0 { parts.append(.images(images)) }
        return parts
    }

    /// 使用者文字清理(§4.2):`# AGENTS.md instructions…` 整段是 harness;移除 `<permissions instructions>` 區塊;
    /// 單一 `<send_user_message_question_reply>` 顯示其內容;剝開頭的 harness 元素;移除 `<image …>` 參照。
    static func userText(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("# AGENTS.md instructions") { return nil }
        if text.wholeMatch(of: /<image[^>]*>|<\/image>/) != nil { return nil }
        text = text.replacing(/<permissions instructions>[\s\S]*?<\/permissions instructions>/, with: "")
        text = text.replacing(/<image name=[^>]*>|<\/image>/, with: "")
        if let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .wholeMatch(of: /<send_user_message_question_reply>([\s\S]*)<\/send_user_message_question_reply>/) {
            text = String(reply.output.1)
        }
        // 開頭的 harness 元素：標籤名含 `_` 或 `-`,或是 `heartbeat`(例:`<environment_context>`、`<in-app-browser-context>`)。
        while true {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = text.prefixMatch(of: /<([A-Za-z][A-Za-z0-9_-]*)[^>]*>/) else { break }
            let tag = String(match.output.1)
            guard tag.contains("_") || tag.contains("-") || tag == "heartbeat",
                  let close = text.range(of: "</\(tag)>") else { break }
            text = String(text[close.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// assistant 文字去掉 `<oai-mem-citation>…</oai-mem-citation>`(含結尾未閉合的)。
    static func assistantText(_ raw: String) -> String? {
        let text = raw.replacing(/<oai-mem-citation>[\s\S]*?<\/oai-mem-citation>/, with: "")
            .replacing(/<oai-mem-citation>[\s\S]*$/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 工具輸入：`arguments` 多半是 JSON 字串;`command` 是 argv 陣列時以空白連接(`sh -c <腳本>` 只顯示腳本)。
    /// `apply_patch` 的輸入是 patch 文字，取第一個 `*** Add/Update/Delete File:` 當路徑。
    private static func toolInput(_ value: Any?) -> (preview: String, path: String?) {
        var arguments = value as? [String: Any]
        if arguments == nil, let text = value as? String {
            arguments = ClaudeTranscriptParser.jsonObject(text)
            if arguments == nil {
                let path = text.firstMatch(of: /\*\*\* (?:Add|Update|Delete) File: ([^\n]+)/).map { String($0.output.1) }
                return (text.truncated(to: 2000), path)
            }
        }
        guard var arguments else { return ("", nil) }
        if let argv = arguments["command"] as? [String] {
            let shells: Set<String> = ["sh", "bash", "zsh", "/bin/sh", "/bin/bash", "/bin/zsh"]
            if argv.count == 3, shells.contains(argv[0]), argv[1] == "-c" || argv[1] == "-lc" {
                arguments["command"] = argv[2]
            } else {
                arguments["command"] = argv.joined(separator: " ")
            }
        }
        return (ClaudeTranscriptParser.inputPreview(arguments), ClaudeTranscriptParser.filePath(in: arguments))
    }

    /// 結果文字：字串，或 `{content: …}`／content block 陣列。
    private static func outputText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let object = value as? [String: Any] { return outputText(object["content"]) }
        return texts(value).joined(separator: "\n")
    }

    /// 結果沒有錯誤旗標，從文字判斷：以 `Script failed`、`failed to spawn`、`aborted by user` 開頭，或**第一個**
    /// `"exit_code": N`／`Process exited with code N`／`Exit code: N` 的 N ≠ 0。
    static func isError(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["Script failed", "failed to spawn", "aborted by user"].contains(where: trimmed.hasPrefix) { return true }
        guard let match = text.firstMatch(of: /"exit_code"\s*:\s*(-?\d+)|Process exited with code (-?\d+)|Exit code: (-?\d+)/) else { return false }
        let code = match.output.1 ?? match.output.2 ?? match.output.3
        return code.map { $0 != "0" } ?? false
    }
}
