import Foundation

/// 要讀的對話紀錄：格式與位置。由 herdr 回報的 session 參照決定，**永不猜檔**(R-I02)。
public struct TranscriptTarget: Sendable, Equatable, Hashable {
    /// 對話紀錄在主機上的位置規則(行為規格 §4)。
    public enum Location: Sendable, Equatable, Hashable {
        /// `<Claude 設定目錄>/projects/<cwd 轉成的資料夾名>/<id>.jsonl`,含 worktree 後備(§4.1)。
        case claude(sessionID: String, cwd: String)
        /// 在 `${GROK_HOME:-$HOME/.grok}/sessions` 下找名稱等於 id 的資料夾(§4.3)。
        case grok(sessionID: String)
        /// `$HOME/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`(§4.4)。
        case antigravity(sessionID: String)
        /// 在 Pi／OMP 的 sessions 資料夾找 `*_<id>.jsonl` 或 `<id>.jsonl`(§4.5)。
        case piJournal(sessionID: String)
        /// integration 以路徑回報的對話紀錄(agy、Pi、OMP)。
        case reportedPath(String)
    }

    public var format: TranscriptFormat
    public var location: Location
    /// 聊天的身分(R-I01):herdr 回報的 session 參照值(id 或路徑)。改變就是另一個聊天。
    public var sessionKey: String

    public init(format: TranscriptFormat, location: Location, sessionKey: String) {
        self.format = format
        self.location = location
        self.sessionKey = sessionKey
    }
}

extension Agent {
    /// 這個 Agent 的對話紀錄;還不知道是哪個 session、參照不安全或這種 agent 沒有可讀的對話紀錄時為 `nil`。
    ///
    /// - kind `id`:必須是安全字元(`^[A-Za-z0-9-]+$`),不符合就拒絕而不是引號化(R-I12)。
    /// - kind `path`:只有 agy、Pi、OMP 接受，且必須是絕對、`.jsonl` 結尾、沒有 `..` 段與 NUL／CR／LF 的路徑(§4.0)。
    public var transcriptTarget: TranscriptTarget? {
        guard let format = TranscriptFormat(agentKind: kind), let session else { return nil }
        let location: TranscriptTarget.Location
        switch session.kind {
        case "id":
            guard ClaudeTranscript.isSafeSessionID(session.value) else { return nil }
            switch format {
            case .claude: location = .claude(sessionID: session.value, cwd: cwd ?? "")
            case .grok: location = .grok(sessionID: session.value)
            case .antigravity: location = .antigravity(sessionID: session.value)
            case .piJournal: location = .piJournal(sessionID: session.value)
            }
        case "path":
            guard format == .antigravity || format == .piJournal, TranscriptReader.isValidPath(session.value) else { return nil }
            location = .reportedPath(session.value)
        default:
            return nil
        }
        return TranscriptTarget(format: format, location: location, sessionKey: session.value)
    }
}
