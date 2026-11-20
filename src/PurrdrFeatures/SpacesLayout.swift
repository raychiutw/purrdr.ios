import Foundation
import PurrdrAgentFeatures
import PurrdrCore

/// 一個 workspace 的 Spaces 版面圖(行為規格 F4):每個 tab 一張分頁圖，裡面是依 herdr 版面排好的 pane 方塊。
///
/// 純投影：同樣的 snapshot 永遠得到同樣的版面圖。顯示的是**開啟當下**的 snapshot,不即時更新。
public struct SpacesLayout: Equatable, Sendable {
    public var tabs: [Tab]

    /// herdr 沒有回報這個 workspace 的版面(`layouts` 缺席，或裡面沒有這個 workspace)時為 `nil`。
    public init?(snapshot: HostSnapshot, workspaceID: String) {
        guard let layouts = snapshot.layouts?.filter({ $0.workspaceID == workspaceID }), !layouts.isEmpty else { return nil }
        let activeTabID = snapshot.workspaces.first { $0.id == workspaceID }?.activeTabID
        let knownTabs = snapshot.tabs.filter { $0.workspaceID == workspaceID }
        let layoutByTab = Dictionary(layouts.map { ($0.tabID, $0) }, uniquingKeysWith: { first, _ in first })
        let panes = Dictionary(snapshot.panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let agents = Dictionary(snapshot.agents.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })

        // snapshot 的 tabs ∪ 只出現在版面的 tab(順序取 id 的 `:t` 尾碼)。
        var entries = knownTabs.map { (id: $0.id, number: $0.number, label: $0.label) }
        for layout in layouts where !entries.contains(where: { $0.id == layout.tabID }) {
            entries.append((layout.tabID, Self.number(fromTabID: layout.tabID), nil))
        }
        tabs = entries.sorted { $0.number < $1.number }.map { entry in
            let layout = layoutByTab[entry.id]
            return Tab(
                id: entry.id, number: entry.number, label: entry.label, isActive: entry.id == activeTabID,
                layout: layout, panes: panes, agents: agents
            )
        }
    }

    /// 只留一個 Tab 的版面圖(從 Spaces 檢視點有多個 pane 的 Tab,#275);找不到時照原樣。
    public func onlyTab(_ tabID: String) -> SpacesLayout {
        guard tabs.contains(where: { $0.id == tabID }) else { return self }
        var layout = self
        layout.tabs = tabs.filter { $0.id == tabID }
        return layout
    }

    /// `w1:tA` → 10:herdr 的 tab 尾碼是十六進位。看不懂時排最後。
    private static func number(fromTabID id: String) -> Int {
        guard let range = id.range(of: ":t", options: .backwards) else { return .max }
        return Int(id[range.upperBound...], radix: 16) ?? .max
    }

    /// 一個 tab 的分頁圖。
    public struct Tab: Identifiable, Equatable, Sendable {
        public var id: String
        public var number: Int
        /// herdr 的 tab 名稱;沒有時畫面顯示「Tab N」。
        public var label: String?
        public var isActive: Bool
        /// 只畫聚焦的 pane(放大)。
        public var isZoomed: Bool
        /// 版面裡的 pane 數(zoomed 時也算全部)。
        public var paneCount: Int
        /// 寬 ÷ 高。字元格約高為寬的兩倍，所以是 (欄 × 0.5) / 列,限制在 0.9–2.4;缺值 1.6。
        public var aspectRatio: Double
        public var blocks: [Block]

        init(
            id: String, number: Int, label: String?, isActive: Bool,
            layout: TabLayout?, panes: [String: Pane], agents: [String: Agent]
        ) {
            self.id = id
            self.number = number
            self.label = label
            self.isActive = isActive
            isZoomed = layout?.zoomed ?? false
            let rects = layout?.panes ?? []
            paneCount = rects.count
            let visible = isZoomed ? rects.filter { $0.paneID == layout?.focusedPaneID } : rects
            let union = Self.union(of: visible.map(\.rect))
            aspectRatio = union.map { $0.height > 0 ? min(2.4, max(0.9, Double($0.width) * 0.5 / Double($0.height))) : 1.6 } ?? 1.6
            blocks = visible.map { rect in
                Block(
                    id: rect.paneID, frame: UnitRect(rect.rect, in: union),
                    pane: panes[rect.paneID], agent: agents[rect.paneID], isFocused: rect.paneID == layout?.focusedPaneID
                )
            }
        }

        private static func union(of rects: [GridRect]) -> GridRect? {
            guard let first = rects.first else { return nil }
            var minX = first.x, minY = first.y, maxX = first.x + first.width, maxY = first.y + first.height
            for rect in rects.dropFirst() {
                minX = min(minX, rect.x)
                minY = min(minY, rect.y)
                maxX = max(maxX, rect.x + rect.width)
                maxY = max(maxY, rect.y + rect.height)
            }
            return GridRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    /// 一個 pane 方塊。
    public struct Block: Identifiable, Equatable, Sendable {
        /// Pane id。
        public var id: String
        /// 在分頁圖裡的位置，以 0…1 表示。
        public var frame: UnitRect
        public var content: Content
        public var isFocused: Bool
        /// 點了要開什麼;只出現在版面、snapshot 沒有這個 pane 時為 `nil`(不能開)。
        public var target: PaneOpenTarget?

        public init(id: String, frame: UnitRect, content: Content, isFocused: Bool, target: PaneOpenTarget?) {
            self.id = id
            self.frame = frame
            self.content = content
            self.isFocused = isFocused
            self.target = target
        }

        init(id: String, frame: UnitRect, pane: Pane?, agent: Agent?, isFocused: Bool) {
            if let agent {
                let name = AgentKind.displayName(agent.kind) ?? agent.kind
                let detail = AgentRowText.sessionTitle(of: agent) ?? agent.name
                self.init(id: id, frame: frame, content: .agent(name: name, detail: detail, status: agent.effectiveStatus),
                          isFocused: isFocused, target: .chat(paneID: id))
            } else if let pane {
                self.init(id: id, frame: frame, content: .terminal(program: Self.program(of: pane)),
                          isFocused: isFocused, target: .terminal(paneID: id))
            } else {
                self.init(id: id, frame: frame, content: .unavailable, isFocused: isFocused, target: nil)
            }
        }

        /// 終端機方塊的程式名：pane 名稱 > 終端機標題 > 資料夾最後一段(依主機的路徑語法，#26)> 空字串(畫面顯示「終端機」)。
        private static func program(of pane: Pane) -> String {
            pane.label ?? pane.terminalTitle ?? pane.cwd.flatMap(HostPathSyntax.lastComponent).map(String.init) ?? ""
        }

        public enum Content: Equatable, Sendable {
            /// agent 顯示名、session 標題或 herdr 名稱、列表上的狀態(`input_pending` 已折算)。
            case agent(name: String, detail: String?, status: AgentStatus)
            /// agent 以外的 pane。
            case terminal(program: String)
            /// 只出現在版面的 pane。
            case unavailable
        }
    }

    /// 以 0…1 表示的矩形。
    public struct UnitRect: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        init(_ rect: GridRect, in union: GridRect?) {
            guard let union, union.width > 0, union.height > 0 else {
                self.init(x: 0, y: 0, width: 1, height: 1)
                return
            }
            self.init(
                x: Double(rect.x - union.x) / Double(union.width), y: Double(rect.y - union.y) / Double(union.height),
                width: Double(rect.width) / Double(union.width), height: Double(rect.height) / Double(union.height)
            )
        }
    }
}

/// 從列表或版面圖要開啟的 Pane。
public enum PaneOpenTarget: Hashable, Sendable {
    /// Agent 的聊天。
    case chat(paneID: String)
    /// Pane 終端機。
    case terminal(paneID: String)
}
