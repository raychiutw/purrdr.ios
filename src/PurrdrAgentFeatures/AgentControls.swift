import Foundation
import PurrdrCore

/// 這個聊天看過的 Agent 控制來源(#561):畫面狀態列、畫面認出的權限模式、看過哪些模式。
/// 只收「觀察」,不做判斷;判斷(優先序、可選項、停用原因)全在 `AgentControls`。
public struct AgentControlObservations: Sendable, Equatable {
    /// 畫面最底下狀態列讀到的模式、模型與 effort(Antigravity,#446);還沒讀到或沒有狀態列是 `nil`。
    public private(set) var screenStatusLine: AgentStatusLine?

    /// 畫面讀到的模式與當時對話紀錄的原文。紀錄沒變就用畫面補「剛切換、紀錄尚未寫入」的空檔;紀錄一更新就以紀錄為準。
    struct ScreenMode: Sendable, Equatable {
        var mode: AgentPermissionMode
        var transcriptValue: String?
    }

    private(set) var screenMode: ScreenMode?
    /// 這個聊天看過的模式(畫面標示、對話紀錄),用來決定輪替裡有沒有略過權限與自動。
    private(set) var observedModes: Set<AgentPermissionMode> = []

    public init() {}

    /// 對話紀錄最新的權限模式原文(載入、還原快取、追蹤更新後呼叫)。
    public mutating func noteTranscript(permissionMode value: String?) {
        if let mode = value.flatMap({ AgentPermissionMode(transcriptValue: $0) }) { observedModes.insert(mode) }
    }

    /// 一批對話紀錄行裡出現過的權限模式都記下(同一批有多次切換時,中間的模式也算看過)。
    public mutating func noteTranscript(lines: [String]) {
        for line in lines where line.contains("\"permissionMode\"") {
            var scratch = TranscriptMetadata()
            scratch.update(with: line)
            noteTranscript(permissionMode: scratch.permissionMode)
        }
    }

    /// 畫面認出的模式:對話紀錄還沒有模式時當作目前模式(`transcriptValue` 是當時紀錄的原文,之後紀錄更新就作廢)。
    public mutating func observeScreen(mode: AgentPermissionMode, transcriptValue: String?) {
        observedModes.insert(mode)
        screenMode = ScreenMode(mode: mode, transcriptValue: transcriptValue)
    }

    /// 畫面認出的模式只用來記錄「看過哪些」(對話紀錄已有模式,以紀錄為準)。
    public mutating func noteSeen(mode: AgentPermissionMode) {
        observedModes.insert(mode)
    }

    /// 畫面狀態列;認不出時呼叫端不要呼叫(沿用上次)。
    public mutating func observeStatusLine(_ line: AgentStatusLine) {
        screenStatusLine = line
    }
}

/// Agent 控制(#561,延伸 ADR-0013):模型、effort、權限模式的**目前值、可選項與停用原因**,收在一個純值型別裡。
///
/// 三個來源只在這裡排優先序:
/// 1. status line 檔(`ClaudeSessionStatus`,Antigravity 裝了 statusline 包裝時)
/// 2. 畫面狀態列(`AgentControlObservations.screenStatusLine`,Antigravity)
/// 3. 對話紀錄 metadata(Claude Code、Codex);權限模式另有畫面補「剛切換、紀錄尚未寫入」的空檔
///
/// 狀態列方言(Antigravity)的權限模式只認 1、2(它的對話紀錄沒有權限模式);其他 Agent 只認 3 加畫面補空檔。
/// 標題列、輸入列膠囊、面板都讀同一份,不各自重寫。停用原因(`permissionModeLock`)也只有一套。
/// 不碰主機、不讀時鐘;切換程序(按鍵、驗證)仍在聊天 model,見 #561 第二步。
public struct AgentControls: Sendable, Equatable {
    /// 停用原因的連線與 Agent 狀態輸入。
    public struct Link: Sendable, Equatable {
        public var isReadOnly: Bool
        public var isOffline: Bool
        /// 已經讀到這個聊天的 Agent(方言的「做不到」原因要有 Agent 才算)。
        public var hasAgent: Bool
        /// 有問題在等使用者回答(`/model` 面板這時不會出現)。
        public var hasPrompt: Bool
        public var agentStatus: AgentStatus

        public init(
            isReadOnly: Bool = false, isOffline: Bool = false, hasAgent: Bool = false, hasPrompt: Bool = false,
            agentStatus: AgentStatus = .unknown
        ) {
            self.isReadOnly = isReadOnly
            self.isOffline = isOffline
            self.hasAgent = hasAgent
            self.hasPrompt = hasPrompt
            self.agentStatus = agentStatus
        }
    }

    /// 面板的權限選項為什麼停用(#380);可切換時是 `nil`。
    public enum PermissionModeLock: Equatable, Sendable {
        case readOnlyDevice
        case offline
        /// Agent 在工作:這個 Agent 的切換只驗證過閒置時(Antigravity)。
        case working
        /// Agent 在等使用者回覆:這時 Shift+Tab 會變成「核准」。
        case waitingForYou
    }

    /// 模型選擇為什麼停用(#384);可選時是 `nil`。停用時膠囊仍可點開 sheet,sheet 只顯示目前模型與這個原因。
    public enum ModelChoiceLock: Equatable, Sendable {
        case readOnlyDevice
        case offline
        /// Agent 在等使用者回覆:這時 `/model` 面板不會出現。
        case waitingForYou
        /// Agent 在工作:`/model` 會排進佇列。
        case working
        /// 這個 Agent 沒有在 app 內切換模型的功能(Codex 等)。
        case agentLacksFeature
        /// 這個 Agent 的切換方式還沒驗證過,所以不開放。
        case notVerified(documentedFor: String)
        /// 這台主機做不到。
        case hostCannot

        public init(_ unavailability: FeatureUnavailability) {
            switch unavailability {
            case .agentLacksFeature: self = .agentLacksFeature
            case .notVerified(let version): self = .notVerified(documentedFor: version)
            case .hostCannot: self = .hostCannot
            }
        }

        /// 對應三種「不能用」的原因;因為唯讀、離線、等你回覆、工作中而停用的不算。
        public var unavailability: FeatureUnavailability? {
            switch self {
            case .agentLacksFeature: .agentLacksFeature
            case .notVerified(let version): .notVerified(documentedFor: version)
            case .hostCannot: .hostCannot
            case .readOnlyDevice, .offline, .waitingForYou, .working: nil
            }
        }
    }

    private let dialect: ScreenDialect
    private let metadata: TranscriptMetadata
    private let observations: AgentControlObservations
    private let statusFile: AgentStatusLine?
    private let link: Link

    public init(
        dialect: ScreenDialect, metadata: TranscriptMetadata, sessionStatus: ClaudeSessionStatus? = nil,
        observations: AgentControlObservations = AgentControlObservations(), link: Link = Link()
    ) {
        self.dialect = dialect
        self.metadata = metadata
        self.observations = observations
        self.link = link
        if dialect.statusLine != nil, let status = sessionStatus {
            statusFile = AgentStatusLine(
                mode: status.cycleMode.flatMap { AgentPermissionMode(antigravityCycleMode: $0) }, model: status.antigravityModelName,
                effort: status.effort)
        } else {
            statusFile = nil
        }
    }

    // MARK: - 值

    /// 這個 Agent 的畫面有可讀的狀態列(Antigravity):模式、模型、effort 只顯示、不能在 app 切換。
    public var readsStatusLine: Bool { dialect.statusLine != nil }

    /// 目前模型的顯示名稱;還沒讀到是 `nil`。
    public var modelName: String? {
        statusFile?.model ?? observations.screenStatusLine?.model ?? metadata.model.map(TranscriptMetadata.displayName(ofModel:))
    }

    /// 目前的 effort 原值。
    public var effortLevel: String? { statusFile?.effort ?? observations.screenStatusLine?.effort ?? metadata.effort }

    /// 目前的 effort 顯示名稱(「中」);還沒讀到是 `nil`。
    public var effortDisplayName: String? { effortLevel.flatMap(Self.effortName(of:)) }

    /// 「Opus 5.5 · 中」;沒有 effort 時只有模型名,還沒讀到是 `nil`。
    public var modelSummary: String? {
        guard let name = modelName else { return nil }
        guard let effort = effortDisplayName else { return name }
        return "\(name) · \(effort)"
    }

    public static func effortName(of level: String) -> String? {
        switch level.lowercased() {
        case "low": String(localized: "Low")
        case "medium": String(localized: "Medium")
        case "high": String(localized: "High")
        case "xhigh": String(localized: "Extra High")
        case "max": String(localized: "Max")
        default: level.isEmpty ? nil : level
        }
    }

    /// 目前的權限模式。狀態列方言以 status line 檔、畫面狀態列為準;其他以對話紀錄尾端最後一筆為準
    /// (電腦端改了也會同步),畫面只補空檔;都沒有是 `nil`。
    public var permissionMode: AgentPermissionMode? {
        if dialect.statusLine != nil, let mode = statusFile?.mode ?? observations.screenStatusLine?.mode { return mode }
        let fromTranscript = metadata.permissionMode.flatMap { AgentPermissionMode(transcriptValue: $0) }
        if let seen = observations.screenMode, seen.transcriptValue == metadata.permissionMode { return seen.mode }
        return fromTranscript ?? observations.screenMode?.mode
    }

    /// Codex 的核准政策原文(例:`on-request`);只顯示,不能在手機切換。其他 Agent 是 `nil`。
    public var approvalPolicy: String? { dialect.showsApprovalPolicy ? metadata.approvalPolicy : nil }

    // MARK: - 可選項與能力

    /// 只有畫面方言有權限模式(Claude Code)且驗證過才開放切換。
    public var supportsPermissionMode: Bool { dialect.switchesPermissionMode }

    /// Shift+Tab 輪替裡有哪些模式:預設一般、接受編輯、Plan;看過略過權限或自動才加入。
    public var permissionModeAvailability: PermissionModeAvailability {
        var availability = PermissionModeAvailability()
        for mode in observations.observedModes { availability.observe(mode) }
        if let permissionMode { availability.observe(permissionMode) }
        return availability
    }

    /// 面板上的模式選項(依輪替順序);目前是 `dontAsk` 時多一列只顯示的它。有自己輪替的 Agent(Antigravity)固定是它輪替裡的幾種。
    public var permissionModeOptions: [AgentPermissionMode] {
        dialect.switchablePermissionModes ?? permissionModeAvailability.options(current: permissionMode)
    }

    /// 模型膠囊要顯示:Claude(可切換),或 Codex 有讀到目前模型(只顯示、說明不能在 app 內切換,#384)。
    public var showsModelCapsule: Bool { supportsPermissionMode || (dialect.showsModelName && modelName != nil) }


    // MARK: - 停用原因

    public var permissionModeLock: PermissionModeLock? {
        if link.isReadOnly { return .readOnlyDevice }
        if link.isOffline { return .offline }
        if link.agentStatus == .blocked { return .waitingForYou }
        if link.agentStatus == .working, dialect.switchesPermissionModeOnlyWhenIdle { return .working }
        return nil
    }

    public var modelChoiceLock: ModelChoiceLock? {
        if link.hasAgent, let reason = dialect.modelChoiceUnavailability { return ModelChoiceLock(reason) }
        if link.isReadOnly { return .readOnlyDevice }
        if link.isOffline { return .offline }
        if link.agentStatus == .blocked || link.hasPrompt { return .waitingForYou }
        if link.agentStatus == .working { return .working }
        return nil
    }

    /// 能開模型選擇所需的聊天狀態(#561):`Link` 之外、只有聊天才知道的輸入。
    public struct ChooseModelInputs: Sendable, Equatable {
        public var hasTarget: Bool
        public var isSending: Bool
        public var hasTypedAnswer: Bool
        public var hasPanel: Bool
        public var isChoosingModel: Bool

        public init(
            hasTarget: Bool = true, isSending: Bool = false, hasTypedAnswer: Bool = false, hasPanel: Bool = false,
            isChoosingModel: Bool = false
        ) {
            self.hasTarget = hasTarget
            self.isSending = isSending
            self.hasTypedAnswer = hasTypedAnswer
            self.hasPanel = hasPanel
            self.isChoosingModel = isChoosingModel
        }
    }

    /// 能開模型選擇:只有 Claude(`/model` 面板一步選定)、閒置、沒有問題在等、沒有別的面板、
    /// 非唯讀與離線。工作中時 `/model` 會排進佇列,所以不開放。
    public func canChooseModel(_ chat: ChooseModelInputs) -> Bool {
        dialect.canChooseModel && chat.hasTarget && !link.isReadOnly && !link.isOffline && !chat.isSending
            && !chat.hasTypedAnswer && !link.hasPrompt && !chat.hasPanel && link.agentStatus != .working
            && link.agentStatus != .blocked && !chat.isChoosingModel
    }

    /// 膠囊可以操作:讀到目前模式、沒在切換、沒有停用原因。
    public func canSwitchPermissionMode(isSwitching: Bool) -> Bool {
        supportsPermissionMode && permissionMode != nil && !isSwitching && permissionModeLock == nil
    }
}

/// 切換權限模式失敗的原因(#306)。
public enum PermissionModeFailure: Error, Equatable, Sendable {
    /// 試了 `attempts` 次，畫面上沒有看到 `target`。
    case notReached(attempts: Int, target: AgentPermissionMode)
    /// 輪替一圈沒有出現目標模式(略過權限、自動):這個 session 沒有開。
    case modeUnavailable(AgentPermissionMode)
    /// 讀不到畫面，不知道目前是哪個模式。
    case unreadable(target: AgentPermissionMode)
    /// 按鍵沒送到主機。
    case keysFailed(target: AgentPermissionMode)
    /// 對話已被換成別的(送出前比對不符)，什麼都沒按。
    case paneChanged(target: AgentPermissionMode)

    /// 再試一次要切到的模式;略過權限沒開時再試沒有意義。
    public var target: AgentPermissionMode? {
        switch self {
        case .notReached(_, let target), .unreadable(let target), .keysFailed(let target), .paneChanged(let target): target
        case .modeUnavailable: nil
        }
    }
}
