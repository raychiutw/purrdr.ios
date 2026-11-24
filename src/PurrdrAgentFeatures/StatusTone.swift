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

/// 聊天列頭像右下角的狀態圓點(#502):四色(`StatusTone`)加實心／空心。
/// 實心＝未讀或正在進行(需要你、工作中、未讀的回覆),空心＝已讀(閒置)。顏色之外的形狀差異只有這一個;
/// 狀態文字由列的 VoiceOver 句子念。
public struct AvatarStatusDot: Equatable, Sendable {
    public var tone: StatusTone
    public var isFilled: Bool

    public init(tone: StatusTone, isFilled: Bool) {
        self.tone = tone
        self.isFilled = isFilled
    }
}

extension AgentStatus {
    /// 列上的狀態圓點。要用已折算未讀的顯示狀態(`ChatUnread.State.displayStatus`):未讀的回覆是 `done`(實心)、已讀是 `idle`(空心)。
    public var statusDot: AvatarStatusDot {
        switch self {
        case .blocked, .working, .done: AvatarStatusDot(tone: tone, isFilled: true)
        case .idle, .unknown: AvatarStatusDot(tone: tone, isFilled: false)
        }
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
