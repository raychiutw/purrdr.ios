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

    public let name: String
    public let verification: Verification
    /// slash 指令開出的面板格式;`nil` 表示不解析面板。
    public let panel: PanelStyle?
    /// 認得 `@` 檔案選擇器(Codex):只能關閉。
    public let detectsFilePicker: Bool
    /// 畫面有權限模式標示、Shift+Tab 輪替(Claude Code)。
    public let hasPermissionModes: Bool
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

    /// 讀面板、送面板按鍵:有面板格式且驗證過。
    public var readsPanels: Bool { panel != nil && isVerified }
    /// 切換權限模式(送 Shift+Tab):有權限模式且驗證過。
    public var switchesPermissionMode: Bool { hasPermissionModes && isVerified }
    /// 在 app 內選模型(送 `/model` 與面板按鍵):驗證過才開放。
    public var canChooseModel: Bool { choosesModel && isVerified }
    /// app 能操作的 session 設定類別(ACP):模式、模型、effort(effort 與模型共用同一組面板)。
    public var configurableCategories: Set<SessionConfigCategory> {
        var result: Set<SessionConfigCategory> = []
        if switchesPermissionMode { result.insert(.mode) }
        if canChooseModel { result.formUnion([.model, .effort]) }
        return result
    }

    /// 測試以 package 建出沒驗證過的方言,驗證開關才有守門的對象。
    package init(
        name: String, verification: Verification, panel: PanelStyle? = nil, detectsFilePicker: Bool = false,
        hasPermissionModes: Bool = false, choosesModel: Bool = false, showsModelName: Bool = false,
        showsApprovalPolicy: Bool = false, readsPromptSuggestions: Bool = false, transcriptStartsAfterFirstMessage: Bool = false
    ) {
        self.name = name
        self.verification = verification
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
    /// 其他種類:不讀面板、不切換、不顯示額外資訊(提示解析仍用通用規則)。
    public static let generic = ScreenDialect(name: "generic", verification: .unverified(documentedFor: "none"))
}
