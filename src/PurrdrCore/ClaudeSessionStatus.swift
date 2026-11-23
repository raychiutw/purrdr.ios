import Foundation

/// Claude Code 的 status line 為一個 session 回報的狀態(#388):context 用量、模型與思考強度。
/// 主機上的包裝腳本每個 session 存一份 `sessions/<session_id>.json`,只取需要的欄位,其餘忽略。
public struct ClaudeSessionStatus: Sendable, Equatable {
    public var sessionID: String
    /// 包裝腳本存下這份狀態的時間。
    public var capturedAt: Date?
    /// `context_window.used_percentage`(0～100);Claude Code 還沒呼叫過 API 時沒有。
    public var contextPercent: Double?
    /// `context_window.context_window_size`(token 數)。
    public var contextWindowSize: Int?
    /// `model.id`(沒有時用 `display_name`)。
    public var model: String?
    /// 思考強度(`effort`);Claude Code 沒回報時沒有。
    public var effort: String?
    /// 權限模式(`cycle_mode`,Antigravity,#448);default 模式與 Claude Code 沒有這個欄位。
    public var cycleMode: String?

    public init(
        sessionID: String, capturedAt: Date? = nil, contextPercent: Double? = nil, contextWindowSize: Int? = nil,
        model: String? = nil, effort: String? = nil, cycleMode: String? = nil
    ) {
        self.sessionID = sessionID
        self.capturedAt = capturedAt
        self.contextPercent = contextPercent
        self.contextWindowSize = contextWindowSize
        self.model = model
        self.effort = effort
        self.cycleMode = cycleMode
    }

    /// 與包裝腳本同一規則(purrdr.host#64):1–128 個英數與 `. _ -`,且不能是 `.` 或 `..`。不合格就不讀(退回對話紀錄算法)。
    public static func isValidSessionID(_ id: String) -> Bool {
        guard (1...128).contains(id.utf8.count), id != ".", id != ".." else { return false }
        return id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
    }

    /// 超過這個時間沒更新的狀態不採用(包裝腳本也在 7 天後清掉檔案)。
    public static let expiry: TimeInterval = 7 * 24 * 60 * 60

    /// 解析 `sessions/<session_id>.json`:`{"captured_at":<epoch 秒>,"session_id":"<id>","status_line_input":<完整輸入>}`。
    public init?(sessionFile data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = object["session_id"] as? String, Self.isValidSessionID(id),
              let input = object["status_line_input"] as? [String: Any]
        else { return nil }
        let window = input["context_window"] as? [String: Any]
        let model = input["model"] as? [String: Any]
        // 沒有 `used_percentage`(null)時 context 不顯示(由退回算法補)。
        let percent = (window?["used_percentage"] as? NSNumber)?.doubleValue
        // Claude Code 的 effort 在輸入根層(`effort.level`),Antigravity 在 `model.effort`。
        let effort = (input["effort"] as? [String: Any])?["level"] as? String ?? input["effort"] as? String
            ?? model?["effort"] as? String
        self.init(
            sessionID: id, capturedAt: (object["captured_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            contextPercent: percent.map { min(100, max(0, $0)) }, contextWindowSize: (window?["context_window_size"] as? NSNumber)?.intValue,
            model: model?["id"] as? String ?? model?["display_name"] as? String, effort: effort,
            cycleMode: input["cycle_mode"] as? String)
    }

    /// 在 `date` 時是否還能用。
    public func isFresh(at date: Date) -> Bool {
        guard let capturedAt else { return true }
        return date.timeIntervalSince(capturedAt) <= Self.expiry
    }
}

/// 讀各 session 的 status line 狀態(SSH:主機上的 session 檔;HTTPS:主機服務的 `usage.session_context`)。
/// 沒有檔案的 session 不出現在結果;整體讀不到(未安裝、舊版主機服務)丟錯,呼叫端退回對話紀錄算法。
public protocol ClaudeSessionStatusReading: Sendable {
    func sessionStatuses(sessionIDs: [String]) async throws -> [String: ClaudeSessionStatus]
}
