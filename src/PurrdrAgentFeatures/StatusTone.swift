import PurrdrCore

/// 狀態色對照表(#237、ADR-0011):顏色只上在符號與圓點，畫面依 tone 取實際色。
public enum StatusTone: Equatable, Sendable {
    /// 需要你與注意：系統橙。
    case attention
    /// 工作中與已連線：主色。
    case accent
    /// 錯誤與失敗：系統紅。
    case error
    /// 其他：中性灰。
    case neutral
}

extension AgentStatus {
    /// 狀態符號與圓點的顏色。
    public var tone: StatusTone {
        switch self {
        case .blocked: .attention
        case .working: .accent
        case .done, .idle, .unknown: .neutral
        }
    }

    /// 狀態字的顏色：不上狀態色(系統橙對白底只有約 2:1)。
    public var textEmphasis: StatusTextEmphasis {
        self == .blocked ? .primary : .secondary
    }
}

/// 狀態字用的中性文字色。
public enum StatusTextEmphasis: Equatable, Sendable {
    /// 主要文字色。
    case primary
    /// 次要文字色(`secondaryText`)。
    case secondary
}

extension ConversationHeader.Status {
    /// 標題下狀態點的顏色，與列表同一張表。
    public var tone: StatusTone {
        switch self {
        case .needsYou: .attention
        case .working: .accent
        case .done, .online, .offline: .neutral
        }
    }
}

extension TerminalStatus {
    /// 終端機標題下狀態點的顏色。
    public var tone: StatusTone {
        switch self {
        case .connected: .accent
        case .waitingForSize, .connecting, .ended: .neutral
        case .disconnected, .inUse, .takenOver, .unavailable: .error
        }
    }
}

extension DelegationStatus {
    /// 委派狀態圖示的顏色。
    public var tone: StatusTone {
        self == .failed ? .error : .neutral
    }
}

extension StopPhase {
    /// 停止列結果符號的顏色(#220);結果文字一律主要色。
    public var tone: StatusTone {
        switch self {
        case .stopping, .stopped: .accent
        case .stillWorking, .unconfirmed, .needsAnswer: .attention
        case .failed, .forceQuitFailed: .error
        }
    }
}
