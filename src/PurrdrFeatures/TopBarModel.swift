import Foundation

// 第一階頂列的邏輯層(#499、#615):不依賴 SwiftUI,可在 swift test 驗證。畫面在 `TopBarViews.swift`。

/// 一個 tab 的頂列內容規格:右側動作、有無主機範圍、有無搜尋。
public struct TopBarSpec: Equatable, Sendable {
    public enum Plus: Sendable { case newChat, upload, addHost }
    public enum Controls: Sendable { case pill, plusOnly, hostScopeOnly, none }

    public var plus: Plus?
    public var hasHostScope: Bool
    public var hasSearch: Bool

    /// 右側控制項的形狀:兩者都有是長型膠囊,只有一個是單顆圓鈕。
    public var controls: Controls {
        switch (hasHostScope, plus != nil) {
        case (true, true): .pill
        case (false, true): .plusOnly
        case (true, false): .hostScopeOnly
        case (false, false): .none
        }
    }
}

extension TopLevelTab {
    /// 這個 tab 的頂列規格(設計稿最終定稿)。`plus` 決定控制項的形狀,內容端(`TopBarContent.plus`)提供對應的按鈕。
    public var topBar: TopBarSpec {
        switch self {
        case .chats: TopBarSpec(plus: .newChat, hasHostScope: true, hasSearch: true)
        case .files: TopBarSpec(plus: .upload, hasHostScope: true, hasSearch: true)
        case .hosts: TopBarSpec(plus: .addHost, hasHostScope: false, hasSearch: false)
        case .traffic: TopBarSpec(plus: nil, hasHostScope: true, hasSearch: false)
        }
    }
}

/// 帳號頭像掛在哪裡(#520、spec #517):頭像要在視窗右上角。
/// 寬視窗的聊天 tab 是兩欄,右上角屬於最右邊那欄(對話欄)的工具列,列表頂列不放;窄視窗收成一疊,回到列表頂列右側(同 iPhone)。
/// 檔案、主機、流量只有一欄,頂列本身跨滿視窗,寬窄都在頂列。
public enum AccountButtonPlacement: Equatable, Sendable {
    /// 共用頂列(`TopBarContent.account`)。
    case topBar
    /// 對話欄的工具列 trailing。
    case detailToolbar

    public static func host(for tab: TopLevelTab, isWideWindow: Bool) -> AccountButtonPlacement {
        tab == .chats && isWideWindow ? .detailToolbar : .topBar
    }

    public static func showsInTopBar(for tab: TopLevelTab, isWideWindow: Bool) -> Bool {
        host(for: tab, isWideWindow: isWideWindow) == .topBar
    }

    public static func showsInDetailToolbar(for tab: TopLevelTab, isWideWindow: Bool) -> Bool {
        host(for: tab, isWideWindow: isWideWindow) == .detailToolbar
    }
}

/// 電腦圖示的主機範圍:篩選某台主機時右上角有小圓點。
public struct TopBarHostScope: Equatable, Sendable {
    public var filteredHostName: String?
    /// 檔案這類「這頁看哪一台」的選擇:永遠有一台,不是篩選,所以不畫小圓點、念「主機:名稱」。
    public var isSelection: Bool

    public init(filteredHostName: String?, isSelection: Bool = false) {
        self.filteredHostName = filteredHostName
        self.isSelection = isSelection
    }

    /// 這頁正在看某一台主機(檔案 tab)。
    public static func selected(hostName: String?) -> TopBarHostScope {
        TopBarHostScope(filteredHostName: hostName, isSelection: true)
    }

    public var showsDot: Bool { !isSelection && filteredHostName != nil }

    /// VoiceOver 念的主機範圍(小圓點只是視覺,名字放在這裡)。
    public var accessibilityLabel: String {
        if isSelection {
            if let filteredHostName { String(localized: "Host: \(filteredHostName)") } else { String(localized: "Host") }
        } else if let filteredHostName {
            String(localized: "Showing: \(filteredHostName)")
        } else {
            String(localized: "Showing: All Hosts")
        }
    }
}

/// 其他畫面(聊天頂列、主機選擇列)仍引用的幾個尺寸;第一階頂列已全交給系統,不再有自己的尺寸(#615)。
/// 聊天頂列改系統後(#612 其他票)這些也會移除。
public enum TopBarMetrics {
    public static let controlHeight: CGFloat = 44
    public static let circleDiameter: CGFloat = 44
    public static let titleCapsuleHeight: CGFloat = 48
    /// 電腦圖示右上角「已篩選某台主機」的小圓點直徑。
    public static let dotDiameter: CGFloat = 9
}
