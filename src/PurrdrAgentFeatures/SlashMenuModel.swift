import Foundation
import Observation
import PurrdrCore

/// 輸入列上方的 slash 選單(#15、行為規格 F9.3)。
///
/// - 游標前是 `/` 加 `[\w:-]*` 時出現(#230):`/` 在草稿開頭是開頭選單(含內建);接在空白後是文中選單，只列 skill 與自訂指令。
/// - 只有 `/` 時依來源分組;輸入名稱後改成單一排名清單(#45):名稱開頭 > 名稱包含 > 說明包含(不分大小寫),
///   同級依分組與原順序。名稱開頭看整個名稱(`kit:review` 不算以 `rev` 開頭)。
/// - 鍵盤：上下移動高亮(停在頭尾)、Return／Tab 選取、Esc 收起(直到離開這段 `/字詞`)。
/// - 選取 = 交給 `onPick`(對話只把 `/名稱 ` 填進輸入框，#83)。
/// - 清單第一次需要時才載入，每個對話只載入一次;`loader` 回傳 `nil` 表示這種 agent 沒有選單。
@MainActor
@Observable
public final class SlashMenuModel {
    public enum Key {
        case up, down, select, dismiss
    }

    private enum Load {
        case idle
        case loading
        case loaded(SlashCatalog?)
    }

    /// 只有 `/` 時顯示的分組;輸入名稱後是空的(改看 `ranked`)。
    public private(set) var sections: [SlashSection] = []
    /// 輸入名稱後的單一排名清單;只有 `/` 時為 `nil`。
    public private(set) var ranked: [SlashCommand]?
    /// 目前畫面上的指令(依顯示順序)。
    public var commands: [SlashCommand] { ranked ?? sections.flatMap(\.commands) }
    /// 高亮的指令名稱。
    public private(set) var highlighted: String?
    /// 選取時呼叫。
    public var onPick: ((SlashCommand) -> Void)?

    /// Esc 收起時那段 `/字詞` 的起點;離開這段(起點改變或不再觸發)才重新出現。
    private var dismissedStart: Int?
    private var state: Load = .idle
    private var loadTask: Task<Void, Never>?
    package var loader: @Sendable () async -> SlashCatalog?

    public init(loader: @escaping @Sendable () async -> SlashCatalog?) {
        self.loader = loader
    }

    /// 選單是否顯示在輸入列上方。
    public var isVisible: Bool {
        guard let trigger, trigger.range.lowerBound != dismissedStart else { return false }
        switch state {
        case .idle: return false
        case .loading: return true
        case .loaded(let catalog): return catalog.map { !Self.available(in: $0, for: trigger.placement).isEmpty } ?? false
        }
    }

    public var isLoading: Bool {
        if case .loading = state { true } else { false }
    }

    /// 發現沒有在時間上限內做完：清單不完整。
    public var isIncomplete: Bool {
        if case .loaded(let catalog?) = state { !catalog.isComplete } else { false }
    }

    /// `/` 在草稿開頭(開頭選單)或接在空白之後(文中選單)。
    public enum Placement: Sendable, Equatable {
        case leading, inline
    }

    /// 游標前正在打的那段 `/字詞`。
    public struct Trigger: Sendable, Equatable {
        /// 要被替換的 `/字詞`(UTF-16 位置，含 `/`)。
        public var range: Range<Int>
        /// `/` 之後到游標的字。
        public var query: String
        public var placement: Placement

        public init(range: Range<Int>, query: String, placement: Placement) {
            self.range = range
            self.query = query
            self.placement = placement
        }

        /// 把這段 `/字詞` 換成 `/名稱 `,其餘文字不動;回傳新草稿與插入文字之後的游標(UTF-16 位置)。
        public func filling(_ name: String, in draft: String) -> (draft: String, caret: Int) {
            let text = draft as NSString
            let inserted = "/\(name) "
            let location = min(range.lowerBound, text.length)
            let length = min(range.upperBound, text.length) - location
            let filled = text.replacingCharacters(in: NSRange(location: location, length: length), with: inserted)
            return (filled, location + (inserted as NSString).length)
        }
    }

    /// 目前觸發的 `/字詞`;沒有時為 `nil`。
    public private(set) var trigger: Trigger?

    /// 游標(UTF-16 位置;有選取範圍時為 `nil`)前的 `/字詞`:`/` 在草稿開頭或前一個字是空白，到游標之間只有名稱字元。
    package static func trigger(in draft: String, caret: Int?) -> Trigger? {
        let utf16 = draft.utf16
        guard let caret, caret >= 0, caret <= utf16.count,
              let end = String.Index(utf16.index(utf16.startIndex, offsetBy: caret), within: draft)
        else { return nil }
        let beforeCaret = draft[..<end]
        guard let slash = beforeCaret.lastIndex(of: "/") else { return nil }
        let name = beforeCaret[beforeCaret.index(after: slash)...]
        guard name.wholeMatch(of: /[\w:-]*/) != nil else { return nil }
        let placement: Placement
        if slash == draft.startIndex {
            placement = .leading
        } else if draft[draft.index(before: slash)].isWhitespace {
            placement = .inline
        } else {
            return nil
        }
        let start = utf16.distance(from: utf16.startIndex, to: slash)
        return Trigger(range: start..<caret, query: String(name), placement: placement)
    }

    /// 草稿或游標改變時呼叫(`caret` 為 UTF-16 位置，有選取範圍時為 `nil`)。觸發且還沒載入時開始載入。
    public func update(draft: String, caret: Int?) {
        let next = Self.trigger(in: draft, caret: caret)
        if dismissedStart != nil, next?.range.lowerBound != dismissedStart { dismissedStart = nil }
        guard next != trigger else { return }
        trigger = next
        refilter()
        if next != nil { startLoading() }
    }

    /// 草稿改變、游標在結尾時呼叫。
    public func update(draft: String) {
        update(draft: draft, caret: draft.utf16.count)
    }

    /// 載入清單(已載入或載入中時等它結束)。
    public func load() async {
        startLoading()
        await loadTask?.value
    }

    /// 狀態在建立 task 的同時就改成載入中，之後的呼叫只會等同一個 task。
    private func startLoading() {
        guard case .idle = state else { return }
        state = .loading
        loadTask = Task {
            let catalog = await self.loader()
            self.state = .loaded(catalog)
            self.refilter()
        }
    }

    /// 處理鍵盤。選單沒顯示時不攔(回傳 false)。
    @discardableResult
    public func handle(_ key: Key) -> Bool {
        guard isVisible else { return false }
        let names = commands.map(\.name)
        let index = highlighted.flatMap { names.firstIndex(of: $0) }
        switch key {
        case .up:
            if let index, index > 0 { highlighted = names[index - 1] }
        case .down:
            if let index { highlighted = names[min(index + 1, names.count - 1)] } else { highlighted = names.first }
        case .select:
            guard let highlighted, let command = commands.first(where: { $0.name == highlighted }) else { return false }
            pick(command)
        case .dismiss:
            dismissedStart = trigger?.range.lowerBound
        }
        return true
    }

    /// 選取一個指令(點選或 Return)。
    public func pick(_ command: SlashCommand) {
        onPick?(command)
    }

    private func refilter() {
        guard let trigger, case .loaded(let catalog?) = state else {
            sections = []
            ranked = nil
            highlighted = nil
            return
        }
        let available = Self.available(in: catalog, for: trigger.placement)
        if trigger.query.isEmpty {
            sections = available
            ranked = nil
        } else {
            sections = []
            ranked = Self.rank(available.flatMap(\.commands), query: trigger.query)
        }
        highlighted = commands.first?.name
    }

    /// 文中選單只列 skill 與自訂指令(內建指令只在開頭有意義)。
    private static func available(in catalog: SlashCatalog, for placement: Placement) -> [SlashSection] {
        placement == .leading ? catalog.sections : catalog.sections.filter { $0.source != .builtIn }
    }

    /// 單一排名(行為規格 F9.3):名稱開頭 > 名稱包含 > 說明包含;同級保留原順序(分組、組內)。
    package static func rank(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
        let needle = query.lowercased()
        func tier(_ command: SlashCommand) -> Int? {
            let name = command.name.lowercased()
            if name.hasPrefix(needle) { return 0 }
            if name.contains(needle) { return 1 }
            if command.summary.lowercased().contains(needle) { return 2 }
            return nil
        }
        return commands.enumerated()
            .compactMap { offset, command in tier(command).map { (tier: $0, offset: offset, command: command) } }
            .sorted { ($0.tier, $0.offset) < ($1.tier, $1.offset) }
            .map(\.command)
    }
}

/// 選定 slash 指令插入輸入框的一次記錄;`sequence` 讓連續插入同一個指令也算改變。
public struct SlashInsertion: Sendable, Equatable {
    /// 插入的指令名稱(不含 `/`)。
    public var name: String
    /// 第幾次插入。
    public var sequence: Int
}
