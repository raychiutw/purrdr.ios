import Foundation

/// 開在新視窗的 Agent 對話或 Pane 終端機(#31)。是 `WindowGroup(for:)` 的值：系統還原視窗時以它重建內容。
///
/// 主機記成 `HostSelection.storedValue`(`demo` 或主機 id),不記主機名稱或位址。
public struct PaneWindow: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case chat
        case terminal
    }

    public var kind: Kind
    private var hostID: String
    public var paneID: String
    /// 開視窗時列表看到的 session(對話比對快取用)。
    public var sessionID: String?
    /// Agent 的標題(終端機的標題、還沒讀到對話前的視窗標題)。
    public var title: String

    public init(kind: Kind, host: HostSelection, paneID: String, sessionID: String?, title: String) {
        self.kind = kind
        hostID = host.storedValue
        self.paneID = paneID
        self.sessionID = sessionID
        self.title = title
    }

    public var host: HostSelection? { HostSelection(storedValue: hostID) }

    /// 目前的主機通道只有選取中主機的;視窗的主機不是它時，內容等使用者選回那台主機。
    public func isAvailable(selection: HostSelection) -> Bool {
        host == selection
    }
}
