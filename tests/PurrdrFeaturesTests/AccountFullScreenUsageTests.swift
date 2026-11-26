import Foundation
import Testing

/// 帳號與設定改滿版 modal、沒登入流程往右推入的原始碼守門(#623、spec #612):
/// 帳號是 `fullScreenCover` 不是 sheet、選擇頁的列由系統 `NavigationLink` 推入、
/// 沒登入流程用系統返回(不自畫「<」)、底部固定區用 `safeAreaBar`(不自鋪 `.bar` 底)。
@Suite("帳號與設定滿版 modal")
struct AccountFullScreenUsageTests {
    private static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: featuresFolder.appending(path: name), encoding: .utf8)
    }

    @Test("帳號與設定:窄視窗 fullScreenCover、寬視窗 page sheet,一般 sheet 的內容不含帳號頁")
    func accountIsFullScreenCover() throws {
        let top = try Self.source("TopNavigationView.swift")
        let cover = try #require(top.range(of: ".accountCover("), "帳號與設定要用 accountCover(iOS 是 fullScreenCover)")
        #expect(top.contains(".fullScreenCover(item: isCompact"), "窄視窗的 accountCover 必須是 fullScreenCover")
        #expect(top.contains("presentationSizing(.page)"), "寬視窗(iPad)的帳號與設定是 page sheet(HIG〈Sheets〉)")
        let memberView = try #require(top.range(of: "MemberView("))
        let sheet = try #require(top.range(of: ".sheet(item:"))
        #expect(cover.lowerBound < memberView.lowerBound && memberView.lowerBound < sheet.lowerBound,
            "MemberView 要在 fullScreenCover 裡,不在 sheet 裡")
    }

    @Test("帳號根頁左上是共用的 X,沒有右上關閉")
    func accountRootClosesWithSharedX() throws {
        let member = try Self.source("MemberView.swift")
        #expect(member.contains("SheetCloseToolbar(identifier: \"member.close\")"))
        #expect(!member.contains("TrailingCloseToolbar"))
    }

    @Test("選擇頁的列是 NavigationLink,列尾 > 由系統給")
    func chooseRowsAreNavigationLinks() throws {
        let text = try Self.source("AccountEntryViews.swift")
        #expect(text.contains("NavigationLink(value: page)"))
        #expect(!text.contains("chevron.right"), "> 由 NavigationLink 給,不自己畫")
        #expect(!text.contains(".pressableRow"), "可點的列用系統按壓回饋")
    }

    @Test("沒登入流程用系統返回鈕,不自畫「<」,也不原地換內容")
    func entryFlowUsesSystemBack() throws {
        let member = try Self.source("MemberView.swift")
        #expect(!member.contains("chevron.backward"), "返回交給系統")
        #expect(!member.contains("member.entry.back"))
        let views = try Self.source("AccountEntryViews.swift")
        #expect(views.contains("NavigationStack(path: $pages)"))
        #expect(views.contains(".navigationDestination(for: AccountEntryFlow.Page.self)"))
        #expect(!views.contains("switch entry.screen"), "各頁由推入的 destination 決定,不看 entry.screen 原地換")
    }

    @Test("登入的對話框掛在 NavigationStack 外層,不掛在會被推入頁蓋住的根頁")
    func entryAlertsLiveOutsideTheStack() throws {
        let views = try Self.source("AccountEntryViews.swift")
        #expect(views.contains(".alert(\"No Member Found\""), "查無會員的對話框要在 AccountEntryStack")
        #expect(views.contains("presenting: model.notice"), "帳號通知對話框要在 AccountEntryStack")
        let member = try Self.source("MemberView.swift")
        #expect(!member.contains(".alert(\"No Member Found\""), "根頁推入登入頁後看不到,不能掛在根頁")
    }

    @Test("底部固定區用 safeAreaBar,不自鋪 .bar 底")
    func bottomBarsUseSafeAreaBar() throws {
        let views = try Self.source("AccountEntryViews.swift")
        #expect(!views.contains(".background(.bar)"))
        #expect(!views.contains("safeAreaInset(edge: .bottom)"))
        #expect(views.contains("safeAreaBar(edge: .bottom)"))
    }

    @Test("通知列的配對入口是系統按鈕,不用手勢加 trait;這支裝置的標示不自畫膠囊")
    func notificationRowsUseSystemControls() throws {
        let push = try Self.source("HostPushSection.swift")
        #expect(!push.contains("TapGesture"), "配對入口用 Button")
        #expect(!push.contains(".accessibilityAddTraits(.isButton)"))
        let devices = try Self.source("PushDevicesSection.swift")
        #expect(devices.contains("LabeledContent"))
        #expect(!devices.contains("background(.quaternary, in: Capsule())"))
    }
}
