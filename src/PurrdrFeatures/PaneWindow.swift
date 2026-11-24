import Foundation
import SwiftUI
import PurrdrAgentFeatures

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

    /// 視窗標題(視窗切換器、Stage Manager 看到的):「Agent 名稱 · 主機」(#519);沒有主機名稱時只有 Agent 名稱。
    public func windowTitle(hostName: String?) -> String {
        guard let hostName, !hostName.isEmpty else { return title }
        return "\(title) · \(hostName)"
    }

    public var host: HostSelection? { HostSelection(storedValue: hostID) }

    /// 視窗要開的聊天。每台主機各自連線(#39),任何一台主機都能開，不必是選取中主機;
    /// 主機已不在這支裝置上(`hostIDs` 裡沒有，例：還原視窗時已刪掉)時為 `nil`。Demo 主機一直都在。
    public func route(hostIDs: some Sequence<UUID>) -> ChatRoute? {
        switch host {
        case .demo?: ChatRoute(host: .demo, paneID: paneID)
        case .host(let id)? where hostIDs.contains(id): ChatRoute(host: .host(id), paneID: paneID)
        default: nil
        }
    }
}

/// 視窗不在前景時,自訂的玻璃控制與狀態點跟著調暗(#519);系統元件由系統處理。
public enum WindowActivity {
    public static func opacity(appearsActive: Bool) -> Double { appearsActive ? 1 : 0.6 }
}

extension View {
    /// 依視窗是否在前景(`appearsActive`)調暗自訂的控制。
    func dimsWhenWindowInactive() -> some View { modifier(WindowActivityDimming()) }
}

private struct WindowActivityDimming: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content.opacity(WindowActivity.opacity(appearsActive: appearsActive))
    }
}

extension EnvironmentValues {
    /// 獨立視窗的標題(`PaneWindowView` 注入);聊天與終端機畫面拿來當 `navigationTitle`。
    @Entry var paneWindowTitle: String?
}
