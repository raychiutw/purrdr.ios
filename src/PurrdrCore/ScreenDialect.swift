import Foundation

/// ACP(Agent Client Protocol)的權限選項種類:畫面方言把各家的「是／總是／否」選項統一成這四種。
public enum PermissionOptionKind: Sendable, Equatable, Hashable {
    case allowOnce, allowAlways, rejectOnce, rejectAlways

    public var isAllow: Bool { self == .allowOnce || self == .allowAlways }

    /// 依選項文字分類(Claude、Codex、Antigravity 的權限提示共通的說法);不像權限選項(例如 AskUserQuestion 的答案)回 `nil`。
    public static func classify(label: String) -> PermissionOptionKind? {
        let text = label.lowercased()
        let persistent = ["don't ask again", "don’t ask again", "always allow", "always deny", "allow all", "during this session", "this conversation"]
            .contains { text.contains($0) }
        let startsWithNo = text.hasPrefix("no") && !(text.dropFirst(2).first?.isLetter ?? false)
        if startsWithNo || text.hasPrefix("deny") || text.hasPrefix("reject") {
            return persistent ? .rejectAlways : .rejectOnce
        }
        if text.hasPrefix("yes") || text.hasPrefix("allow") || text.hasPrefix("approve") || text.hasPrefix("proceed") {
            return persistent ? .allowAlways : .allowOnce
        }
        return nil
    }
}

/// 一個權限選項(ACP `PermissionOption`):畫面上的選項加上統一的種類。
public struct PermissionOption: Sendable, Equatable {
    public let option: PromptOption
    public let kind: PermissionOptionKind
}

/// session 設定選項的類別(ACP `SessionConfigOption` 的 category):模式、模型、effort(ACP 稱 thought level)。
public enum SessionConfigCategory: Sendable, Equatable, Hashable {
    case mode, model, effort
}

/// 一個 session 設定選項:類別、可選的值與目前值(從 slash 面板解析)。
public struct SessionConfigOption: Sendable, Equatable {
    public let category: SessionConfigCategory
    public let values: [String]
    public let currentIndex: Int?
}

extension SlashPanel {
    /// 這張面板在調的 session 設定:有層級滑桿是 effort,有選項列的是 model(目前只有 `/model`、`/effort` 兩種面板);其他回 `nil`。
    public var sessionConfig: SessionConfigOption? {
        if let slider {
            return SessionConfigOption(category: .effort, values: slider.levels, currentIndex: slider.current)
        }
        guard !options.isEmpty else { return nil }
        return SessionConfigOption(category: .model, values: options.map(\.label), currentIndex: options.firstIndex(where: \.isCurrent))
    }
}

extension BlockedPrompt {
    /// 權限提示的選項(ACP 權限選項):同時有同意與拒絕的選項才算權限提示,否則空陣列(例如問答)。
    public var permissionOptions: [PermissionOption] {
        let classified = options.compactMap { option in
            PermissionOptionKind.classify(label: option.label).map { PermissionOption(option: option, kind: $0) }
        }
        guard classified.contains(where: { $0.kind.isAllow }), classified.contains(where: { !$0.kind.isAllow }) else { return [] }
        return classified
    }
}

/// 功能不能用的三種原因(ADR-0013、#451):畫面依原因說不同的話,使用者才知道要不要等更新。
public enum FeatureUnavailability: Equatable, Sendable {
    /// 這個 Agent 沒有這項功能(設定檔沒有那組方言)。
    case agentLacksFeature
    /// 方言有,但還沒用真實 Agent 驗證過(會送按鍵的操作不開放);帶文件依據的 Agent 版本。
    case notVerified(documentedFor: String)
    /// 這台主機做不到(主機服務太舊、Windows 不支援等)。
    case hostCannot
}

/// Agent 設定檔的畫面組(ADR-0013、#441):從 pane 畫面讀到什麼、能操作什麼。
///
/// 方言是常數表,以 `name` 為身分。**會送按鍵的操作**(面板、權限模式切換、`/model`)沒驗證過就不開放(`isVerified`):
/// 畫面改成只顯示、請使用者到終端機操作。純讀取的(提示解析、建議、目前模型)不受驗證管制。
public struct ScreenDialect: Sendable, Equatable {
    public typealias Verification = TranscriptDialect.Verification

    /// slash 面板的畫面格式。
    public enum PanelStyle: Sendable, Equatable {
        /// 頂端 `▔` 分隔、`Esc to cancel` 提示行(Claude Code)。
        case claude
        /// Codex 的面板。
        case codex
    }

    /// 畫面最底下一行的狀態列格式。
    public enum StatusLineStyle: Sendable, Equatable {
        /// Antigravity:右下角「模式 · 模型 · effort」(default 模式沒有模式那一段,#446)。
        case antigravity
    }

    public let name: String
    /// 讀取畫面與切換權限模式用真實錄製驗證到哪個版本。
    public let verification: Verification
    /// 面板與選模型(要在面板上移動游標再選定)的驗證;沒有另外指定時同 `verification`。
    /// Antigravity 錄過面板的畫面,但沒錄過選定後的結果,所以這一項維持未驗證(#447)。
    public let panelVerification: Verification
    /// 狀態列格式;`nil` 表示不讀。只讀取、不送按鍵,所以不受驗證開關管制。
    public let statusLine: StatusLineStyle?
    /// slash 指令開出的面板格式;`nil` 表示不解析面板。
    public let panel: PanelStyle?
    /// 認得 `@` 檔案選擇器(Codex):只能關閉。
    public let detectsFilePicker: Bool
    /// 畫面有權限模式標示、Shift+Tab 輪替(Claude Code、Antigravity)。
    public let hasPermissionModes: Bool
    /// 這個 Agent 的 Shift+Tab 輪替順序(Antigravity,#447);`nil` 表示用 Claude Code 的輪替(`AgentPermissionMode.next`)。
    public let permissionModeCycle: [AgentPermissionMode]?
    /// 只在閒置時切換權限模式:錄製只有閒置時的輪替,工作中按 Shift+Tab 的行為沒驗證過(Antigravity)。
    public let switchesPermissionModeOnlyWhenIdle: Bool
    /// `/model` 面板一步選定(Claude Code);其他種類只顯示目前模型。
    public let choosesModel: Bool
    /// 顯示目前模型(膠囊):Claude Code 一定顯示,Codex 有讀到模型時也顯示(只顯示)。
    public let showsModelName: Bool
    /// 顯示核准政策原文(Codex)。
    public let showsApprovalPolicy: Bool
    /// 畫面灰色字的下一步建議(Claude Code)。
    public let readsPromptSuggestions: Bool
    /// 第一則訊息送出後才有對話紀錄(Codex):等待畫面的說明不同。
    public let transcriptStartsAfterFirstMessage: Bool

    public var isVerified: Bool {
        if case .verified = verification { true } else { false }
    }

    public var isPanelVerified: Bool {
        if case .verified = panelVerification { true } else { false }
    }

    /// 讀面板、送面板按鍵:有面板格式且面板驗證過。
    public var readsPanels: Bool { panel != nil && isPanelVerified }
    /// 切換權限模式(送 Shift+Tab):有權限模式且驗證過。
    public var switchesPermissionMode: Bool { hasPermissionModes && isVerified }
    /// 在 app 內選模型(送 `/model` 與面板按鍵):驗證過才開放。
    public var canChooseModel: Bool { choosesModel && isPanelVerified }
    /// 選模型不能用的原因;能用時 `nil`。
    public var modelChoiceUnavailability: FeatureUnavailability? { unavailability(hasCapability: choosesModel, verification: panelVerification) }
    /// 切換權限模式不能用的原因;能用時 `nil`。
    public var permissionModeUnavailability: FeatureUnavailability? { unavailability(hasCapability: hasPermissionModes, verification: verification) }

    private func unavailability(hasCapability: Bool, verification: Verification) -> FeatureUnavailability? {
        guard hasCapability else { return .agentLacksFeature }
        guard case .unverified(let documentedFor) = verification else { return nil }
        return .notVerified(documentedFor: documentedFor)
    }

    /// app 能操作的 session 設定類別(ACP):模式、模型、effort(effort 與模型共用同一組面板)。
    public var configurableCategories: Set<SessionConfigCategory> {
        var result: Set<SessionConfigCategory> = []
        if switchesPermissionMode { result.insert(.mode) }
        if canChooseModel { result.formUnion([.model, .effort]) }
        return result
    }

    /// 測試以 package 建出沒驗證過的方言,驗證開關才有守門的對象。
    package init(
        name: String, verification: Verification, panelVerification: Verification? = nil, statusLine: StatusLineStyle? = nil,
        panel: PanelStyle? = nil, detectsFilePicker: Bool = false, hasPermissionModes: Bool = false,
        permissionModeCycle: [AgentPermissionMode]? = nil, switchesPermissionModeOnlyWhenIdle: Bool = false,
        choosesModel: Bool = false, showsModelName: Bool = false,
        showsApprovalPolicy: Bool = false, readsPromptSuggestions: Bool = false, transcriptStartsAfterFirstMessage: Bool = false
    ) {
        self.name = name
        self.verification = verification
        self.panelVerification = panelVerification ?? verification
        self.permissionModeCycle = permissionModeCycle
        self.switchesPermissionModeOnlyWhenIdle = switchesPermissionModeOnlyWhenIdle
        self.statusLine = statusLine
        self.panel = panel
        self.detectsFilePicker = detectsFilePicker
        self.hasPermissionModes = hasPermissionModes
        self.choosesModel = choosesModel
        self.showsModelName = showsModelName
        self.showsApprovalPolicy = showsApprovalPolicy
        self.readsPromptSuggestions = readsPromptSuggestions
        self.transcriptStartsAfterFirstMessage = transcriptStartsAfterFirstMessage
    }
}

extension ScreenDialect {
    static let claude = ScreenDialect(
        name: "claude", verification: .verified(agentVersion: "Claude Code 2.1.300–2.1.325"), panel: .claude,
        hasPermissionModes: true, choosesModel: true, showsModelName: true, readsPromptSuggestions: true
    )
    static let codex = ScreenDialect(
        name: "codex", verification: .verified(agentVersion: "Codex 0.157–0.163"), panel: .codex, detectsFilePicker: true,
        showsModelName: true, showsApprovalPolicy: true, transcriptStartsAfterFirstMessage: true
    )
    /// Antigravity 1.5.14(#446、#447):讀狀態列(模式、模型、effort),以 Shift+Tab 切換權限模式(輪替順序 auto → plan →
    /// default → accept-edits,與切換後的狀態列都是真實錄製;只在閒置時切換)。`/model`、`/effort` 面板的畫面錄過,但選定
    /// (Enter)後的結果與是否寫進設定沒錄過,所以選模型維持未驗證(`panelVerification`);需要錄的項目見 Fixtures/README.md。
    static let antigravity = ScreenDialect(
        name: "antigravity", verification: .verified(agentVersion: "Antigravity CLI 1.5.14"),
        panelVerification: .unverified(documentedFor: "Antigravity CLI 1.5.14"), statusLine: .antigravity,
        hasPermissionModes: true, permissionModeCycle: [.auto, .plan, .normal, .acceptEdits],
        switchesPermissionModeOnlyWhenIdle: true, choosesModel: true, showsModelName: true
    )
    /// 其他種類:不讀面板、不切換、不顯示額外資訊(提示解析仍用通用規則)。
    public static let generic = ScreenDialect(name: "generic", verification: .unverified(documentedFor: "none"))
}

/// 從畫面狀態列讀到的 session 設定(#446):權限模式、模型顯示名與 effort。
public struct AgentStatusLine: Sendable, Equatable {
    public let mode: AgentPermissionMode?
    public let model: String?
    public let effort: String?

    public init(mode: AgentPermissionMode?, model: String?, effort: String?) {
        self.mode = mode
        self.model = model
        self.effort = effort
    }
}

extension ScreenDialect {
    /// 讀 pane 畫面最底下一行的狀態列;這個方言沒有狀態列、或最後一行不是狀態列(認不出)回 `nil`,呼叫端沿用上次。
    public func readStatusLine(in screen: String) -> AgentStatusLine? {
        switch statusLine {
        case .antigravity: AntigravityStatusLine.parse(screen)
        case nil: nil
        }
    }
}

/// Antigravity 的狀態列(真實畫面 agy 1.5.14):畫面最後一個非空行的右半段是「模式 · 模型 · effort」;
/// 權限模式 default 時沒有模式那一段(只有「模型 · effort」);面板、提示開著時它仍在最底下。
enum AntigravityStatusLine {
    private static let efforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    static func parse(_ screen: String) -> AgentStatusLine? {
        guard let last = screen.split(separator: "\n", omittingEmptySubsequences: true)
            .last(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        // 左邊可能有提示(`? for shortcuts`、`esc to cancel`),與右邊的狀態以兩個以上的空白隔開。
        let text = String(last).trimmingCharacters(in: .whitespaces)
        let chunk = text.range(of: #"\s{2,}"#, options: [.regularExpression, .backwards]).map { String(text[$0.upperBound...]) } ?? text
        let segments = chunk.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard segments.count == 2 || segments.count == 3, let effort = segments.last?.lowercased(), efforts.contains(effort),
              !segments.contains(where: \.isEmpty) else { return nil }
        let mode: AgentPermissionMode
        if segments.count == 3 {
            guard let known = modes[segments[0]] else { return nil }
            mode = known
        } else {
            mode = .normal
        }
        return AgentStatusLine(mode: mode, model: segments[segments.count - 2], effort: effort)
    }

    static let modes: [String: AgentPermissionMode] = [
        "default": .normal, "auto": .auto, "accept-edits": .acceptEdits, "plan": .plan,
    ]

    /// statusline 的模型名稱(`Gemini 4 Neon (Medium)`)去掉後面標示 effort 的括號,與畫面狀態列、對話紀錄的名稱一致。
    static func displayModel(_ name: String) -> String {
        guard let open = name.range(of: " (", options: .backwards), name.hasSuffix(")") else { return name }
        return String(name[..<open.lowerBound])
    }
}

extension AgentPermissionMode {
    /// Antigravity statusline 的 `cycle_mode`(`auto`、`plan`、`accept-edits`;default 模式沒有這個欄位);認不得是 `nil`。
    public init?(antigravityCycleMode value: String) {
        guard let mode = AntigravityStatusLine.modes[value] else { return nil }
        self = mode
    }
}

extension ClaudeSessionStatus {
    /// 去掉括號的模型名稱(Antigravity 的 statusline 把 effort 寫在名稱後面)。
    public var antigravityModelName: String? { model.map(AntigravityStatusLine.displayModel) }
}

extension ScreenDialect {
    /// 按一次 Shift+Tab 到的下一個模式:有自己的輪替(Antigravity)就照它,否則同 Claude Code 的 `AgentPermissionMode.next`。
    /// 不在輪替裡的目前模式按下去回到輪替的第一個。
    public func nextPermissionMode(
        after mode: AgentPermissionMode, available: Set<AgentPermissionMode> = AgentPermissionMode.defaultAvailable
    ) -> AgentPermissionMode {
        guard let cycle = permissionModeCycle else { return mode.next(available: available) }
        guard let index = cycle.firstIndex(of: mode) else { return cycle[0] }
        return cycle[(index + 1) % cycle.count]
    }

    /// 有自己輪替的方言可切換的模式(依面板顯示順序,即 `AgentPermissionMode.switchableOrder` 的順序);沒有自己輪替是 `nil`。
    public var switchablePermissionModes: [AgentPermissionMode]? {
        permissionModeCycle.map { cycle in AgentPermissionMode.switchableOrder.filter { cycle.contains($0) } }
    }

    /// 從畫面讀目前的權限模式:有狀態列的讀狀態列(Antigravity),否則讀 Claude Code 的畫面標示;認不出回 `nil`。
    /// 沒有權限模式的方言一律 `nil`。
    public func readPermissionMode(in screen: String) -> AgentPermissionMode? {
        guard hasPermissionModes else { return nil }
        if statusLine != nil { return readStatusLine(in: screen)?.mode }
        return PermissionModeScreen.parse(screen)
    }
}
