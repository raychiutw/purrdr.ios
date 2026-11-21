/// herdr 的 Tab(GLOSSARY「Workspace／Tab／Pane」)。
public struct Tab: Sendable, Equatable, Identifiable {
    /// Tab id(例如 `w1:tA`)。
    public var id: String
    public var workspaceID: String
    /// 在 workspace 內的順序。
    public var number: Int
    public var label: String?

    public init(id: String, workspaceID: String, number: Int, label: String?) {
        self.id = id
        self.workspaceID = workspaceID
        self.number = number
        self.label = label
    }
}

/// herdr 的 Pane:真正的終端機。agent 以外的 pane(shell、build、`npm run dev`)也在這裡。
public struct Pane: Sendable, Equatable, Identifiable {
    /// Pane id(例如 `w1:pA`)。
    public var id: String
    public var workspaceID: String
    public var tabID: String
    /// 在這個 pane 偵測到的 agent 種類;agent 以外的 pane 為 `nil`。
    public var agentKind: String?
    public var cwd: String?
    /// pane 自己的名稱(schema 的 `label`)。
    public var label: String?
    /// 終端機標題(已去掉狀態符號)。shell pane 通常是前景程式名。
    public var terminalTitle: String?
    /// herdr 重啟後無法還原這個 pane 的原因。
    public var restoreError: String?
    /// 這個 pane 的 PTY 列數(snapshot 的 `scroll.viewport_rows`);保留電腦版面的 Pane 終端機用(#357)。
    public var viewportRows: Int?

    public init(
        id: String, workspaceID: String, tabID: String, agentKind: String? = nil, cwd: String? = nil,
        label: String? = nil, terminalTitle: String? = nil, restoreError: String? = nil, viewportRows: Int? = nil
    ) {
        self.viewportRows = viewportRows
        self.id = id
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.agentKind = agentKind
        self.cwd = cwd
        self.label = label
        self.terminalTitle = terminalTitle
        self.restoreError = restoreError
    }
}

/// 一個 tab 的版面(snapshot 的 `layouts[]`)。
public struct TabLayout: Sendable, Equatable {
    public var workspaceID: String
    public var tabID: String
    /// 只顯示聚焦的 pane(放大)。
    public var zoomed: Bool
    public var focusedPaneID: String?
    public var panes: [PaneRect]

    public init(workspaceID: String, tabID: String, zoomed: Bool, focusedPaneID: String?, panes: [PaneRect]) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.zoomed = zoomed
        self.focusedPaneID = focusedPaneID
        self.panes = panes
    }

    public struct PaneRect: Sendable, Equatable {
        public var paneID: String
        public var rect: GridRect

        public init(paneID: String, rect: GridRect) {
            self.paneID = paneID
            self.rect = rect
        }
    }
}

/// 以終端機字元格為單位的矩形。
public struct GridRect: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
