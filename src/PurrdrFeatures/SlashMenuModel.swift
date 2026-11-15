import Observation
import PurrdrCore

/// 輸入列上方的 slash 選單(#15、行為規格 F9.3)。
///
/// - 草稿**恰好**是 `/` 加 `[\w:-]*`(後面沒有空白或其他字)時出現。
/// - 依來源分組;輸入名稱時在每組內篩選(名稱或說明包含，不分大小寫),空的分組拿掉。
///   單一排名清單(名稱開頭 > 名稱包含 > 說明包含)屬於 Slash 進階(#45)。
/// - 鍵盤：上下移動高亮(停在頭尾)、Return／Tab 選取、Esc 收起(直到草稿離開 slash 狀態)。
/// - 選取 = 把草稿換成 `/名稱 `(結尾空白，選單隨之收起);由使用者按送出。直接送出與「有副作用只填入」的規則屬於 #45。
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

    /// 目前顯示的分組(已依搜尋篩選)。
    public private(set) var sections: [SlashSection] = []
    /// 高亮的指令名稱。
    public private(set) var highlighted: String?
    /// 選取時呼叫，參數是新的草稿。
    public var onPick: ((String) -> Void)?

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
        let names = sections.flatMap(\.commands).map(\.name)
        let index = highlighted.flatMap { names.firstIndex(of: $0) }
        switch key {
        case .up:
            if let index, index > 0 { highlighted = names[index - 1] }
        case .down:
            if let index { highlighted = names[min(index + 1, names.count - 1)] } else { highlighted = names.first }
        case .select:
            guard let highlighted, let command = sections.flatMap(\.commands).first(where: { $0.name == highlighted }) else { return false }
            pick(command)
        case .dismiss:
            dismissed = true
        }
        return true
    }

    /// 選取一個指令(點選或 Return):草稿換成 `/名稱 `。
    public func pick(_ command: SlashCommand) {
        onPick?("/\(command.name) ")
    }

    private func refilter() {
        guard let query, case .loaded(let catalog?) = state else {
            sections = []
            highlighted = nil
            return
        }
        let needle = query.lowercased()
        sections = catalog.sections.compactMap { section in
            let commands = needle.isEmpty ? section.commands : section.commands.filter {
                $0.name.lowercased().contains(needle) || $0.summary.lowercased().contains(needle)
            }
            return commands.isEmpty ? nil : SlashSection(source: section.source, commands: commands)
        }
        highlighted = sections.first?.commands.first?.name
    }
}
