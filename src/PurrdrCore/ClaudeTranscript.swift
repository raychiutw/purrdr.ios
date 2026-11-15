import Foundation

/// Claude Code 對話紀錄的位置規則(行為規格 §4.1)。
///
/// 路徑是 `<設定目錄>/projects/<cwd 轉成的資料夾名>/<session id>.jsonl`;設定目錄在主機上由
/// `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` 決定(`TranscriptCommand.locate`)。
public enum ClaudeTranscript {
    /// Claude Code 2.1.280 起的資料夾名規則(R-I11):每個不是 `[A-Za-z0-9]` 的 UTF-16 code unit 換成 `-`
    /// (emoji 是兩個 unit,所以是 `--`);結果超過 200 字時取前 200 字,加 `-` 與原 cwd 的 Java `hashCode`
    /// 取絕對值的 base36。
    public static func projectFolder(forCWD cwd: String) -> String {
        let units = cwd.utf16.map { unit -> UInt16 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: unit
            default: 0x2D
            }
        }
        let replaced = String(decoding: units, as: UTF16.self)
        guard units.count > 200 else { return replaced }
        return String(decoding: units.prefix(200), as: UTF16.self) + "-" + String(javaHashCode(cwd).magnitude, radix: 36)
    }

    /// Java `String.hashCode`:`h = 31 * h + c`,以 UTF-16 code unit 計、32 位元溢位。
    static func javaHashCode(_ text: String) -> Int32 {
        text.utf16.reduce(Int32(0)) { hash, unit in hash &* 31 &+ Int32(unit) }
    }

    /// session id 只能含英數與 `-`(行為規格 §4.0、R-I12):不符合就拒絕，而不是引號化了事。
    static func isSafeSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "-"): true
            default: false
            }
        }
    }
}

extension Agent {
    /// Claude Code 的 session id:只有 `kind == "id"`、非空且是安全字元時才有(路徑參照對 Claude 一律不接受)。
    /// 沒有就表示還不知道是哪個 session——此時永不猜檔(R-I02)。
    public var claudeSessionID: String? {
        guard kind == "claude", let session, session.kind == "id", ClaudeTranscript.isSafeSessionID(session.value) else { return nil }
        return session.value
    }
}

extension ClaudeTranscript {
    /// 對話紀錄的 session 資料夾(放 subagent 與 workflow 檔,§4.6):主對話紀錄去掉 `.jsonl`;subagent 的對話紀錄
    /// 取 `/subagents/` 之前的部分(subagent 的 subagent 平放在同一個主 session 下)。
    public static func sessionFolder(ofTranscript path: String) -> String {
        if let range = path.range(of: "/subagents/") { return String(path[..<range.lowerBound]) }
        return path.hasSuffix(".jsonl") ? String(path.dropLast(6)) : path
    }

    /// Workflow 裡 agent 的對話紀錄:`<session>/subagents/workflows/<runId>/agent-<id>.jsonl`。id 不安全時沒有。
    public static func workflowAgentTranscript(sessionFolder: String, runID: String, agentID: String) -> String? {
        guard isSafeDelegationID(runID), isSafeDelegationID(agentID), isValidFolder(sessionFolder) else { return nil }
        return "\(sessionFolder)/subagents/workflows/\(runID)/agent-\(agentID).jsonl"
    }

    /// subagent／workflow／呼叫 id 只能是 `^[A-Za-z0-9_-]{1,128}$`(§4.0):不符合就拒絕，不是引號化了事。
    static func isSafeDelegationID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "-"), UInt8(ascii: "_"): true
            default: false
            }
        }
    }

    /// 主機上的資料夾：絕對路徑、沒有 `..` 段、沒有 NUL／CR／LF。
    static func isValidFolder(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.split(separator: "/").contains("..")
            && !path.contains { $0 == "\0" || $0 == "\r" || $0 == "\n" }
    }
}
