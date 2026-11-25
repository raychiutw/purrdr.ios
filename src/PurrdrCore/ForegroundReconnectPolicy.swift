import Foundation

/// 進背景後 SSH／HTTPS 連線「大概還活著」的時間(#550、#551 共用)。
///
/// iOS 在 app 被 suspend 時就把 TCP 連線 defunct(`docs/research/ssh-background-disconnect.md` §2.3);
/// background task 約可多撐 30 秒,保留 25 秒留一點餘裕。
public enum BackgroundRetention {
    public static let duration: TimeInterval = 25
}

/// 回到前景時連線要沿用還是重撥(純邏輯,時間由呼叫端算好傳入)。
public enum ForegroundReconnectPolicy {
    public enum Decision: Equatable, Sendable {
        /// 背景不久,連線應該還活著:照舊沿用。
        case reuse
        /// 背景超過保留時間:當連線已斷,直接丟棄並重撥(不探測)。
        case redial
    }

    public static func decision(backgroundSeconds: TimeInterval) -> Decision {
        backgroundSeconds > BackgroundRetention.duration ? .redial : .reuse
    }

    /// 診斷紀錄(category `hosts`)的一行。
    public static func logLine(backgroundSeconds: TimeInterval, decision: Decision) -> String {
        "背景 \(Int(backgroundSeconds)) 秒，\(decision == .reuse ? "沿用" : "重撥")"
    }
}

/// 列表「連線中」的顯示時機:回前景重連時畫面先顯示快取,前 1～2 秒不出現「連線中」。
public enum ConnectingDisplayPolicy {
    public enum Display: Equatable, Sendable {
        case hidden
        case connecting
        case stillConnecting
    }

    /// 安靜重連(回前景、手上有快取)的前這幾秒不顯示。
    public static let quietGrace: TimeInterval = 1.5
    /// 連線這麼久還沒結果就顯示「仍在連線」。
    public static let slowThreshold: TimeInterval = 10

    public static func display(elapsed: TimeInterval, isQuietReconnect: Bool) -> Display {
        if elapsed >= slowThreshold { return .stillConnecting }
        if isQuietReconnect, elapsed < quietGrace { return .hidden }
        return .connecting
    }
}
