import Foundation

// 共用頂列的邏輯層(#499):不依賴 SwiftUI,可在 swift test 驗證。畫面在 `TopBarViews.swift`。

/// 一個 tab 的頂列內容規格:右側動作、有無主機範圍、有無搜尋。
public struct TopBarSpec: Equatable, Sendable {
    public enum Plus: Sendable { case newChat, upload, addHost }
    public enum Controls: Sendable { case pill, plusOnly, hostScopeOnly, none }
    public enum Collapsed: Sendable { case searchCapsule, smallTitleCapsule }

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

    /// 往下滑時的收法:有搜尋的收成搜尋膠囊,其餘收成置中小標題膠囊。
    public var collapsed: Collapsed { hasSearch ? .searchCapsule : .smallTitleCapsule }
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

/// 標題列與搜尋欄的版面(以安全區頂端為 0;數字見 `TopBarMetrics`)。
public struct TopBarLayout: Equatable, Sendable {
    public var hasSearch: Bool
    /// 字級放大倍率(1 = 預設字級)。
    public var typeScale: CGFloat

    public init(hasSearch: Bool, typeScale: CGFloat = 1) {
        self.hasSearch = hasSearch
        self.typeScale = typeScale
    }

    /// 大標題字級:隨 Dynamic Type 放大,最多 1.5 倍。
    public var titleSize: CGFloat { TopBarMetrics.titleSize * min(typeScale, TopBarMetrics.titleScaleCap) }
    /// 標題列高度:max(52, 字級 × 1.2)。
    public var titleRowHeight: CGFloat { max(TopBarMetrics.titleRowMinHeight, titleSize * 1.2) }
    /// 未收合的搜尋欄高度:最多放大 1.45 倍。
    public var searchHeight: CGFloat { TopBarMetrics.searchHeight * min(typeScale, TopBarMetrics.searchScaleCap) }

    /// 內容(列表)的起點:有搜尋的在搜尋欄下 10pt,沒有的在標題列下 10pt。
    public var contentInset: CGFloat {
        let bottom = hasSearch ? titleRowHeight + TopBarMetrics.searchGap + searchHeight : titleRowHeight
        return bottom + TopBarMetrics.contentGap
    }

    /// 搜尋欄頂端:未收合在標題列下 4pt,收合貼在安全區頂端下 4pt。
    public func searchTop(progress: CGFloat) -> CGFloat {
        Self.interpolate(titleRowHeight + TopBarMetrics.searchGap, TopBarMetrics.collapsedSearchTop, progress)
    }

    /// 搜尋欄高度:收合後是 44pt 的玻璃膠囊。
    public func searchHeight(progress: CGFloat) -> CGFloat {
        Self.interpolate(searchHeight, TopBarMetrics.collapsedSearchHeight, progress)
    }

    private static func interpolate(_ from: CGFloat, _ to: CGFloat, _ progress: CGFloat) -> CGFloat {
        from + (to - from) * progress
    }
}

/// 往下滑的收合進度:捲動 56pt 內完成;標題列(標題、控制項與頭像)淡出並上移 26pt。
public struct TopBarScroll: Equatable, Sendable {
    /// 列表相對靜止位置往下捲的距離(負值是下拉橡皮筋)。
    public var offset: CGFloat
    public init(offset: CGFloat) { self.offset = offset }

    public var progress: CGFloat { min(max(offset / TopBarMetrics.collapseDistance, 0), 1) }
    public var isCollapsed: Bool { progress >= 1 }
    public var titleOpacity: CGFloat { 1 - progress }
    public var titleOffset: CGFloat { -TopBarMetrics.titleLift * progress }
}

/// 頂列的尺寸與字級(#475、#499):所有 tab 的標題、按鈕、膠囊、頭像共用,不散在各畫面。數字出自設計稿最終定稿(單位 pt,402 寬為基準)。
/// 聊天畫面的單行標題膠囊(`titleCapsuleHeight`)也是同一個高度(#476)。
public enum TopBarMetrics {
    // MARK: 按鈕與膠囊
    /// 按鈕與膠囊的高度,也是 HIG 的最小觸控目標。
    public static let controlHeight: CGFloat = 44
    /// 圓形按鈕的直徑。
    public static let circleDiameter: CGFloat = 44
    /// 聊天畫面單行標題膠囊的高度:與其他 tab 頂端一致。
    public static let titleCapsuleHeight: CGFloat = controlHeight
    /// 長型膠囊 [電腦圖示｜＋] 的寬度(兩段各 46,中間分隔線)。
    public static let pillWidth: CGFloat = 95
    public static let pillSegmentWidth: CGFloat = 46
    public static let pillDividerHeight: CGFloat = 20
    /// 膠囊與頭像的間距。
    public static let controlSpacing: CGFloat = 8
    /// 圖示大小(膠囊內)。
    public static let iconSize: CGFloat = 22
    /// 頭像圓鈕裡的字級。
    public static let avatarInitialSize: CGFloat = 17
    /// 電腦圖示右上角「已篩選某台主機」的小圓點:直徑與離圖示段右、上緣的距離。
    public static let dotDiameter: CGFloat = 9
    public static let dotInset: CGFloat = 8

    // MARK: 邊距
    public static let leadingMargin: CGFloat = 20
    public static let trailingMargin: CGFloat = 16
    public static let searchMargin: CGFloat = 16

    // MARK: 標題與搜尋
    public static let titleSize: CGFloat = 34
    public static let titleScaleCap: CGFloat = 1.5
    public static let titleRowMinHeight: CGFloat = 52
    public static let searchHeight: CGFloat = 40
    public static let searchScaleCap: CGFloat = 1.45
    /// 標題列與搜尋欄的間距;搜尋欄(或標題列)到內容起點的間距。
    public static let searchGap: CGFloat = 4
    public static let contentGap: CGFloat = 10

    // MARK: 捲動收合
    public static let collapseDistance: CGFloat = 56
    public static let titleLift: CGFloat = 26
    public static let collapsedSearchTop: CGFloat = 4
    public static let collapsedSearchHeight: CGFloat = 44
    /// 沒有搜尋的 tab 收合後的置中小標題膠囊:高、左右內距、字級。
    public static let smallTitleHeight: CGFloat = 40
    public static let smallTitleInset: CGFloat = 20
    public static let smallTitleSize: CGFloat = 17
    /// 內容從狀態列下滑過時,上緣的漸層遮罩高度。
    public static let fadeMaskHeight: CGFloat = 64
}
