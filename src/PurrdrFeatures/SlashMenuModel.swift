import Observation
import PurrdrCore

/// 輸入列上方的 slash 選單(#15、行為規格 F9.3)。
///
/// - 草稿**恰好**是 `/` 加 `[\w:-]*`(後面沒有空白或其他字)時出現。
/// - 只有 `/` 時依來源分組;輸入名稱後改成單一排名清單(#45):名稱開頭 > 名稱包含 > 說明包含(不分大小寫),
///   同級依分組與原順序。名稱開頭看整個名稱(`kit:review` 不算以 `rev` 開頭)。
/// - 鍵盤：上下移動高亮(停在頭尾)、Return／Tab 選取、Esc 收起(直到草稿離開 slash 狀態)。
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

    private var query: String?
    private var dismissed = false
    private var state: Load = .idle
    private var loadTask: Task<Void, Never>?
    var loader: @Sendable () async -> SlashCatalog?

    public init(loader: @escaping @Sendable () async -> SlashCatalog?) {
        self.loader = loader
    }

    /// 選單是否顯示在輸入列上方。
    public var isVisible: Bool {
        guard query != nil, !dismissed else { return false }
        switch state {
        case .idle: return false
        case .loading: return true
        case .loaded(let catalog): return catalog != nil
        }
    }

    public var isLoading: Bool {
        if case .loading = state { true } else { false }
    }

    /// 發現沒有在時間上限內做完：清單不完整。
    public var isIncomplete: Bool {
        if case .loaded(let catalog?) = state { !catalog.isComplete } else { false }
    }

    /// 草稿是 slash 選單狀態時的查詢字串(不含 `/`)。
    static func query(of draft: String) -> String? {
        guard draft.hasPrefix("/"), draft.dropFirst().wholeMatch(of: /[\w:-]*/) != nil else { return nil }
        return String(draft.dropFirst())
    }

    /// 草稿改變時呼叫。進入 slash 狀態且還沒載入時開始載入。
    public func update(draft: String) {
        let next = Self.query(of: draft)
        if next == nil { dismissed = false }
        guard next != query else { return }
        query = next
        refilter()
        if next != nil { startLoading() }
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
            dismissed = true
        }
        return true
    }

    /// 選取一個指令(點選或 Return)。
    public func pick(_ command: SlashCommand) {
        onPick?(command)
    }

    private func refilter() {
        guard let query, case .loaded(let catalog?) = state else {
            sections = []
            ranked = nil
            highlighted = nil
            return
        }
        if query.isEmpty {
            sections = catalog.sections
            ranked = nil
        } else {
            sections = []
            ranked = Self.rank(catalog.sections.flatMap(\.commands), query: query)
        }
        highlighted = commands.first?.name
    }

    /// 單一排名(行為規格 F9.3):名稱開頭 > 名稱包含 > 說明包含;同級保留原順序(分組、組內)。
    static func rank(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
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
