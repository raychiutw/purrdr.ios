import Foundation

/// Claude Code 對話紀錄(JSONL)的解析器(行為規格 §4.1)。
///
/// 一行一個 JSON 物件;entry 層 camelCase、content block snake_case。只有 `type` 為 `user`、`assistant`
/// 的行(加上排隊中 prompt 的 `queued_command` attachment)會產生訊息，其他 type(`api-request-blob`、
/// `system`、`attachment`…)一律忽略——`api-request-blob` 也帶 `message`,不能只看有沒有 `message`。
/// 對話紀錄是 Claude Code 的內部檔案，不是公開 API。
public enum ClaudeTranscriptParser {
    /// 解析一行。看不懂的行(通常是被截斷的尾行)回傳空陣列。
    public static func messages(in line: String) -> [TranscriptMessage] {
        guard let object = jsonObject(line) else { return [] }
        let id = (object["uuid"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stableID(of: line)
        let isSidechain = object["isSidechain"] as? Bool ?? false
        let date = (object["timestamp"] as? String).flatMap(parseDate)
        switch object["type"] as? String {
        case "assistant":
            let parts = assistantParts(object)
            guard !parts.isEmpty else { return [] }
            return [TranscriptMessage(id: id, role: .assistant, date: date, isSidechain: isSidechain, parts: parts)]
        case "user":
            let parts = isHarness(object) ? harnessParts(object) : userParts(object)
            guard !parts.isEmpty else { return [] }
            let role: TranscriptMessage.Role = parts.allSatisfy(\.isNoteOrSkill) ? .system : .user
            return [TranscriptMessage(id: id, role: role, date: date, isSidechain: isSidechain, parts: parts)]
        case "attachment":
            guard let message = queuedPrompt(object, id: id, date: date, isSidechain: isSidechain) else { return [] }
            return [message]
        default:
            return []
        }
    }

    // MARK: - assistant

    private static func assistantParts(_ object: [String: Any]) -> [TranscriptPart] {
        let message = object["message"] as? [String: Any]
        if let text = message?["content"] as? String {
            return text.isBlank ? [] : [.text(text)]
        }
        let blocks = message?["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { block -> TranscriptPart? in
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String, !text.isBlank else { return nil }
                return .text(text)
            case "thinking":
                // 新版 Claude Code 的 thinking 只留簽章、內容是空字串:隱藏。
                guard let text = block["thinking"] as? String, !text.isBlank else { return nil }
                return .thinking(text)
            case "tool_use":
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                if name == "Skill", let skill = input["skill"] as? String, !skill.isEmpty {
                    return .skill(name: skill)
                }
                if let delegation = delegationCall(name: name, id: block["id"] as? String, input: input) {
                    return .delegation(delegation)
                }
                return .toolCall(id: block["id"] as? String, name: name, input: inputPreview(input), path: filePath(in: input))
            default:
                return nil
            }
        }
    }

    /// 工具輸入的扁平化預覽：常見欄位直接取值，其他列成 `key: value`。最多 2,000 字。
    static func inputPreview(_ input: [String: Any]) -> String {
        for key in ["command", "file_path", "notebook_path", "path", "pattern", "url", "query", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return value.truncated(to: 2000) }
        }
        let lines = input.keys.sorted().map { key in "\(key): \(flatten(input[key]))" }
        return lines.joined(separator: "\n").truncated(to: 2000)
    }

    private static func flatten(_ value: Any?) -> String {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        case let value?:
            (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
        case nil: ""
        }
    }

    static func filePath(in input: [String: Any]) -> String? {
        for key in ["file_path", "notebook_path", "path"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - user

    /// Harness 行(使用者沒打的):`isMeta`、`isCompactSummary`、`promptSource:"system"`、`origin.kind` 不是 `human`。
    private static func isHarness(_ object: [String: Any]) -> Bool {
        if object["isMeta"] as? Bool == true || object["isCompactSummary"] as? Bool == true { return true }
        if object["promptSource"] as? String == "system" { return true }
        if let origin = object["origin"] as? [String: Any], origin["kind"] as? String != "human" { return true }
        return false
    }

    /// Harness 行永不成為使用者泡泡，只可能產生背景任務通知、hand-back(§4.1),或 slash 指令載入的 skill:
    /// skill 全文以 harness 行記錄(沒有 `sourceToolUseID`),只顯示「已載入 skill」,不貼全文。
    /// 由 `Skill` 工具載入的(有 `sourceToolUseID`)已由呼叫本身顯示。
    private static func harnessParts(_ object: [String: Any]) -> [TranscriptPart] {
        let delegationParts = delegationReports(object)
        if !delegationParts.isEmpty { return delegationParts }
        guard object["isMeta"] as? Bool == true, object["sourceToolUseID"] == nil else { return [] }
        let prefix = "Base directory for this skill: "
        guard let text = texts(in: object).first, text.hasPrefix(prefix) else { return [] }
        let path = text.dropFirst(prefix.count).prefix { $0 != "\n" }
        guard let name = path.split(separator: "/").last, !name.isEmpty else { return [] }
        return [.skill(name: String(name))]
    }

    private static func userParts(_ object: [String: Any]) -> [TranscriptPart] {
        let content = (object["message"] as? [String: Any])?["content"]
        if let text = content as? String { return userTextParts(text) }
        var parts: [TranscriptPart] = []
        var images = 0
        for block in content as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                parts += userTextParts(block["text"] as? String ?? "")
            case "image":
                images += 1
            case "tool_result":
                parts.append(.toolResult(
                    callID: block["tool_use_id"] as? String,
                    text: toolResultText(block["content"]).truncated(to: 4000),
                    isError: block["is_error"] as? Bool ?? false
                ))
            default:
                break
            }
        }
        if images > 0 { parts.append(.images(images)) }
        return parts
    }

    private static func toolResultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func texts(in object: [String: Any]) -> [String] {
        let content = (object["message"] as? [String: Any])?["content"]
        if let text = content as? String { return [text] }
        return (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    }

    /// 使用者文字 → 片段:本地指令輸出成為系統註記，其餘清理後成為文字。
    static func userTextParts(_ raw: String) -> [TranscriptPart] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["local-command-stdout", "local-command-stderr"] {
            if let inner = wholeElement(tag, in: trimmed) {
                let note = stripANSI(inner).replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).truncated(to: 600)
                return note.isEmpty ? [] : [.note(note)]
            }
        }
        let text = cleanUserText(raw)
        return text.isEmpty ? [] : [.text(text)]
    }

    /// 行為規格 §4.1「使用者文字清理」。
    static func cleanUserText(_ raw: String) -> String {
        var text = raw
        // 長貼上:`<pasted_content id="N">…</pasted_content id="N">` 解開(#79)。
        text = text.replacingMatches(#"<pasted_content id="(\d+)">([\s\S]*?)</pasted_content id="\1">"#, with: "$2")
        if let command = firstElement("command-name", in: text) {
            let args = (firstElement("command-args", in: text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return args.isEmpty ? command.trimmingCharacters(in: .whitespacesAndNewlines) : "\(command.trimmingCharacters(in: .whitespacesAndNewlines)) \(args)"
        }
        if let command = firstElement("bash-input", in: text) {
            return "! " + command.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 剝掉開頭的 harness 元素(標籤名含 `_`、`-`,或 heartbeat、image)。人打的 task-notification、agent-message 保留。
        while true {
            let head = text.drop { $0.isWhitespace }
            guard let match = head.firstMatch(of: /^<([A-Za-z][A-Za-z0-9_-]*)(\s[^>]*)?>/) else { break }
            let name = String(match.output.1)
            guard name.contains("_") || name.contains("-") || name == "heartbeat" || name == "image",
                  name != "task-notification", name != "agent-message",
                  let close = head.range(of: "</\(name)>") else { break }
            text = String(head[close.upperBound...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 排隊中的 prompt

    /// Claude 忙碌時送進來的 prompt 只以 `queued_command` attachment 記錄,不會有 `user` 行(#77)。
    private static func queuedPrompt(_ object: [String: Any], id: String, date: Date?, isSidechain: Bool) -> TranscriptMessage? {
        guard let attachment = object["attachment"] as? [String: Any],
              attachment["type"] as? String == "queued_command" else { return nil }
        // 排隊中的任務通知(只有 harness 寫的才算;人打的是 prompt 模式)。
        if attachment["commandMode"] as? String == "task-notification", let prompt = attachment["prompt"] as? String,
           (attachment["origin"] as? [String: Any])?["kind"] as? String != "human" {
            let parts = taskNotifications(in: prompt).map(TranscriptPart.taskNotification)
            guard !parts.isEmpty else { return nil }
            let when = (attachment["timestamp"] as? String).flatMap(parseDate) ?? date
            return TranscriptMessage(id: id, role: .system, date: when, isSidechain: isSidechain, parts: parts)
        }
        guard attachment["commandMode"] as? String == "prompt",
              let prompt = attachment["prompt"] as? String else { return nil }
        if let origin = attachment["origin"] as? [String: Any], origin["kind"] as? String != "human" { return nil }
        let text = cleanUserText(prompt)
        guard !text.isEmpty else { return nil }
        let when = (attachment["timestamp"] as? String).flatMap(parseDate) ?? date
        return TranscriptMessage(id: id, role: .user, date: when, isSidechain: isSidechain, parts: [.text(text)])
    }

    // MARK: - 工具

    static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// ISO 8601(含或不含毫秒)。
    static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: .iso8601)
    }

    /// 沒有 `uuid` 的行：以行內容算確定性雜湊(FNV-1a 64),每次讀都得到同一個 id。
    /// 主機讀取時已剝掉圖片資料，所以雜湊的就是去除圖片後的內容。
    static func stableID(of line: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in line.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return "line-" + String(hash, radix: 16)
    }

    private static func wholeElement(_ tag: String, in text: String) -> String? {
        guard text.hasPrefix("<\(tag)>"), text.hasSuffix("</\(tag)>") else { return nil }
        let inner = text.dropFirst(tag.count + 2).dropLast(tag.count + 3)
        return inner.contains("<\(tag)>") ? nil : String(inner)
    }

    private static func firstElement(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// 去掉 ANSI 跳脫序列(CSI 與 OSC)。正規式裡一定要真的含 ESC 字元(R-Q10)。
    static func stripANSI(_ text: String) -> String {
        text.replacingMatches("\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "")
            .replacingMatches("\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "")
            .replacingMatches("\u{1B}[@-Z\\\\-_]", with: "")
    }
}

/// Header 中繼資料：模型、context token、effort(行為規格 §4.1、F5.7)。
public struct TranscriptMetadata: Sendable, Equatable, Codable {
    public var model: String?
    public var contextTokens: Int?
    public var effort: String?

    public init(model: String? = nil, contextTokens: Int? = nil, effort: String? = nil) {
        self.model = model
        self.contextTokens = contextTokens
        self.effort = effort
    }

    /// 依序看過 `lines`,較晚的值覆蓋較早的。只看 assistant 行;`<synthetic>` 模型或 `isApiErrorMessage`
    /// 的行(API 錯誤、限流、登入過期)永不設定模型與 context(#80)。本地指令 `/effort` 的輸出也會更新 effort。
    public static func latest(in lines: [String]) -> TranscriptMetadata {
        var metadata = TranscriptMetadata()
        for line in lines { metadata.update(with: line) }
        return metadata
    }

    /// 以一行更新。
    public mutating func update(with line: String) {
        guard let object = ClaudeTranscriptParser.jsonObject(line) else { return }
        switch object["type"] as? String {
        case "assistant":
            let message = object["message"] as? [String: Any] ?? [:]
            let model = message["model"] as? String
            guard model != "<synthetic>", object["isApiErrorMessage"] as? Bool != true else { return }
            if let model, !model.isEmpty { self.model = model }
            let usage = message["usage"] as? [String: Any] ?? [:]
            let counts = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { usage[$0] as? Int }
            // 一個數字都沒有是 nil 而不是 0,否則合併時會蓋掉真值。
            if !counts.isEmpty { contextTokens = counts.reduce(0, +) }
            if let effort = object["effort"] as? String, effort.wholeMatch(of: /[a-z]{1,16}/) != nil { self.effort = effort }
        case "user":
            for case .note(let note) in ClaudeTranscriptParser.messages(in: line).flatMap(\.parts) {
                if let match = note.firstMatch(of: /Set effort level to ([a-z]{1,16})/) { effort = String(match.output.1) }
            }
        default:
            break
        }
    }

    /// 模型顯示名：去掉 `[…]` 尾碼與 `provider/` 前綴;`claude-opus-4-1-…` → 「Opus 4.1」;
    /// 舊式 `claude-3-5-sonnet` → 「Sonnet 3.5」;非 Claude id 只去掉 `provider/` 前綴(行為規格 F5.7、R-I18:
    /// Pi／OMP 的模型帶 provider 前綴)。
    public static func displayName(ofModel model: String) -> String {
        let unprefixed = model.lastIndex(of: "/").map { String(model[model.index(after: $0)...]) } ?? model
        var id = unprefixed
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        let tokens = id.split(separator: "-").map(String.init)
        guard tokens.first == "claude", tokens.count >= 2 else { return unprefixed }
        let isVersion = { (token: String) in token.count <= 2 && token.allSatisfy(\.isNumber) }
        let family: String
        let version: [String]
        if isVersion(tokens[1]) {
            version = Array(tokens.dropFirst().prefix(while: isVersion))
            guard let name = tokens.dropFirst(1 + version.count).first else { return model }
            family = name
        } else {
            family = tokens[1]
            version = Array(tokens.dropFirst(2).prefix(while: isVersion))
        }
        guard family.allSatisfy(\.isLetter) else { return model }
        let title = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? title : "\(title) \(version.joined(separator: "."))"
    }
}

extension TranscriptPart {
    /// 不是使用者打的內容(系統註記、skill、任務通知、hand-back):整則訊息都是這些時角色是 system。
    var isNoteOrSkill: Bool {
        switch self {
        case .note, .skill, .taskNotification, .handBack: true
        default: false
        }
    }
}

extension String {
    var isBlank: Bool { allSatisfy(\.isWhitespace) }

    /// 超過 `limit` 個字元時截斷並加上「…」。
    func truncated(to limit: Int) -> String {
        count > limit ? String(prefix(limit)) + "…" : self
    }

    func replacingMatches(_ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        return regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
}
