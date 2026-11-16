import Foundation

/// Claude Code 對話紀錄中委派(subagent、workflow)相關的解析(行為規格 F10、§4.6)。
///
/// 格式是 Claude Code 的內部格式。樣本取自 2.1.317–2.1.325 的真實對話紀錄:
/// - 背景 agent 的啟動結果以「Async agent launched」開頭，含 `agentId: <id>`;workflow 以「Workflow launched」開頭，含 `Run ID: wf_…`。
/// - 前景 agent 的結果是 hand-back 框:「[Subagent hand-back] … The report follows:」之後每行縮排兩格的報告，
///   接著 `agentId: …` 與 `<usage>subagent_tokens: N\ntool_uses: N\nduration_ms: N</usage>`。
/// - 任務通知:`<task-notification><task-id>…<tool-use-id>…<status>…<summary>…<result>…<usage>…</task-notification>`;
///   續跑後的通知可能只有 task-id。
extension ClaudeTranscriptParser {
    // MARK: - 呼叫

    static func delegationCall(name: String, id: String?, input: [String: Any]) -> DelegationCall? {
        switch name {
        case "Agent", "Task":
            let description = (input["description"] as? String).flatMap { $0.isBlank ? nil : $0 }
            let background = input["run_in_background"] as? Bool == true || (input["run_in_background"] as? String)?.lowercased() == "true"
            return DelegationCall(
                kind: .subagent, callID: id, title: description,
                agentType: (input["subagent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                model: (input["model"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isBackground: background
            )
        case "Workflow":
            let meta = (input["script"] as? String).flatMap(workflowMeta(inScript:))
            let pathName = (input["scriptPath"] as? String ?? input["script_path"] as? String).flatMap(workflowName(fromScriptPath:))
            return DelegationCall(kind: .workflow, callID: id, title: meta?.name ?? pathName, detail: meta?.description, isBackground: true)
        default:
            return nil
        }
    }

    /// 腳本中的 `meta = { name: '…', description: '…' }`(寬鬆比對：單雙反引號都接受)。
    static func workflowMeta(inScript script: String) -> (name: String?, description: String?)? {
        // 轉成 String:Android 的 Foundation 只有 String 版的 `Range(_:in:)`,Substring 編譯不過。
        guard let block = (script.firstMatch(of: /meta\s*=\s*\{([\s\S]*?)\}/)?.output.1).map(String.init) else { return nil }
        func field(_ key: String) -> String? {
            let pattern = key + #"\s*:\s*(['"`])((?:(?!\1)[\s\S])*)\1"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
                  let range = Range(match.range(at: 2), in: block) else { return nil }
            let value = String(block[range])
            return value.isBlank ? nil : value
        }
        let name = field("name")
        let description = field("description")
        return name == nil && description == nil ? nil : (name, description)
    }

    /// `…/<name>-wf_<run>.js` → `<name>`。
    static func workflowName(fromScriptPath path: String) -> String? {
        guard let file = HostPathSyntax.lastComponent(path),
              let match = file.wholeMatch(of: /(.+)-wf_[A-Za-z0-9_-]+\.js/) else { return nil }
        return String(match.output.1)
    }

    // MARK: - 回報(只從 harness 行)

    /// Harness 行中的任務通知與 hand-back。
    static func delegationReports(_ object: [String: Any]) -> [TranscriptPart] {
        var parts: [TranscriptPart] = []
        if let origin = object["origin"] as? [String: Any], origin["kind"] as? String == "peer", origin["handback"] as? Bool == true,
           let from = origin["from"] as? String, let body = origin["body"] as? String, let report = handBackReport(in: body) {
            return [.handBack(from: from, report: report)]
        }
        for text in texts(in: object) {
            parts += taskNotifications(in: text).map(TranscriptPart.taskNotification)
            for match in text.matches(of: /<agent-message from="([^"]+)">([\s\S]*?)<\/agent-message>/) {
                if let report = handBackReport(in: String(match.output.2)) {
                    parts.append(.handBack(from: String(match.output.1), report: report))
                }
            }
        }
        return parts
    }

    /// 文字中的每個 `<task-notification>` 區塊。需要有 `status`,以及 `tool-use-id` 或 `task-id`
    /// (續跑之後的通知只有 task-id)。tokens 取 `subagent_tokens` 或 `total_tokens`。
    static func taskNotifications(in text: String) -> [TaskNotification] {
        text.matches(of: /<task-notification>([\s\S]*?)<\/task-notification>/).compactMap { match in
            let block = String(match.output.1)
            func element(_ tag: String) -> String? {
                guard let open = block.range(of: "<\(tag)>"),
                      let close = block.range(of: "</\(tag)>", range: open.upperBound..<block.endIndex) else { return nil }
                let value = block[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            guard let status = element("status") else { return nil }
            let callID = element("tool-use-id")
            let taskID = element("task-id")
            guard callID != nil || taskID != nil else { return nil }
            return TaskNotification(
                taskID: taskID, callID: callID, status: status, summary: element("summary"), result: element("result"),
                tokens: element("subagent_tokens").flatMap { Int($0) } ?? element("total_tokens").flatMap { Int($0) },
                toolUses: element("tool_uses").flatMap { Int($0) }, durationMs: element("duration_ms").flatMap { Int($0) }
            )
        }
    }

    /// Hand-back 報告：「The report follows:」之後、每行去掉兩格縮排的文字;遇到沒有縮排的行(`agentId: …`、`<usage>`)停止。
    static func handBackReport(in text: String) -> String? {
        guard let marker = text.range(of: "The report follows:") else { return nil }
        var lines: [String] = []
        for line in text[marker.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            if line.hasPrefix("  ") {
                lines.append(String(line.dropFirst(2)))
            } else if line.allSatisfy(\.isWhitespace) {
                lines.append("")
            } else {
                break
            }
        }
        while lines.last?.isBlank == true { lines.removeLast() }
        while lines.first?.isBlank == true { lines.removeFirst() }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// 工具結果文字中的委派資訊(給 `Conversation` 判斷卡片狀態用)。
enum DelegationResultText {
    /// 「Async agent launched…agentId: X」→ X。
    static func asyncAgentID(in text: String) -> String? {
        guard text.hasPrefix("Async agent launched") else { return nil }
        return agentID(in: text)
    }

    /// 「Workflow launched…Run ID: wf_…」→ run id。
    static func workflowRunID(in text: String) -> String? {
        guard text.hasPrefix("Workflow launched") else { return nil }
        return text.firstMatch(of: /Run ID:\s*(wf_[A-Za-z0-9_-]+)/).map { String($0.output.1) }
    }

    static func agentID(in text: String) -> String? {
        text.firstMatch(of: /agentId:\s*([A-Za-z0-9_-]+)/).map { String($0.output.1) }
    }

    /// `SendMessage` 的結果 `{"resumedAgentId":"X",…}` → X。
    static func resumedAgentID(in text: String) -> String? {
        text.firstMatch(of: /"resumedAgentId"\s*:\s*"([A-Za-z0-9_-]+)"/).map { String($0.output.1) }
    }

    /// 前景結果尾端的 `<usage>subagent_tokens: N\ntool_uses: N\nduration_ms: N</usage>`。
    static func usage(in text: String) -> (tokens: Int?, toolUses: Int?) {
        guard let block = (text.firstMatch(of: /<usage>([\s\S]*?)<\/usage>/)?.output.1).map(String.init) else { return (nil, nil) }
        func number(_ key: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: key + #"\s*:\s*(\d+)"#),
                  let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
                  let range = Range(match.range(at: 1), in: block) else { return nil }
            return Int(block[range])
        }
        return (number("subagent_tokens") ?? number("total_tokens"), number("tool_uses"))
    }

    /// 前景結果顯示的報告:hand-back 框取報告;否則去掉尾端的 `agentId:` 行與 `<usage>` 區塊。
    static func report(in text: String) -> String {
        if let report = ClaudeTranscriptParser.handBackReport(in: text) { return report }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let usage = lines.lastIndex(where: { $0.hasPrefix("<usage>") }) { lines.removeSubrange(usage...) }
        if lines.last?.hasPrefix("agentId:") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
