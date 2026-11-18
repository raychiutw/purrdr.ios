/// 長駐追蹤腳本(#166)的協定：讀取上限與回應關鍵字。腳本的 POSIX 版(`TranscriptCommand.followScript`)與 Windows 版
/// (`WindowsScripts.follow`)照這裡輸出;`SSHTranscriptFollower` 的解析、流量守門的計量與 `scripts/windows-follow-repro.py`
/// (啟動時從 `TranscriptReader.swift` 讀上限)都以這裡為準。
package enum TranscriptFollowProtocol {
    /// 一次讀的上限(bytes)。
    package static let limit = TranscriptReader.catchUpLimit
    /// 落後超過 `limit` 時一次讀的上限(bytes)。
    package static let backlogLimit = TranscriptReader.catchUpBacklogLimit
    /// 版本或錨點不知道時的佔位。
    package static let unknown = "-"

    /// 回應的第一個字。`appended` 之後是紀錄行(以數字開頭),最後一行以 `end` 開頭。
    package enum Keyword: String, CaseIterable, Sendable {
        case unchanged
        case replaced
        case error
        case appended
        case end
    }

    /// 這一行是一則回應的最後一行(`unchanged`、`replaced`、`error` 或 `end` 開頭)。
    package static func endsReply(_ line: String) -> Bool {
        guard let first = line.split(separator: " ", maxSplits: 1).first, let keyword = Keyword(rawValue: String(first)) else { return false }
        return keyword != .appended
    }
}
