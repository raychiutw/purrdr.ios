import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import Testing
@testable import PurrdrFeatures

/// 第二層隱藏 tab bar 由各 tab 的導覽路徑決定(使用者錄影:返回列表後 tab bar 晚約 0.4 秒才出現)。
/// 隱藏設定掛在被推入的頁面上時,返回動畫期間頁面還在、隱藏要等它移除才失效;
/// 改由路徑擁有者在堆疊根決定,返回一開始路徑就變了,tab bar 跟著轉場出現(見 docs/research/tabbar-hide-on-push.md)。
@Suite("推入頁的 tab bar")
struct TabBarOnPushTests {
    static let route = ChatRoute(host: .demo, paneID: "w1:p1")

    @Test("聊天 tab:路徑上有聊天(對話或 Pane 終端機)就隱藏;只有版面圖或空路徑時顯示")
    func chatsPath() {
        #expect(![ChatsDestination]().hidesTabBar)
        #expect([ChatsDestination.chat(Self.route)].hidesTabBar)
        #expect(![ChatsDestination.layout(SpacesLayoutRoute(host: .demo, workspaceID: "w1", title: "ledger"))].hidesTabBar)
        #expect([ChatsDestination.layout(SpacesLayoutRoute(host: .demo, workspaceID: "w1", title: "ledger")), .chat(Self.route)].hidesTabBar)
    }

    @Test("主機 tab:只有登入 Shell 隱藏")
    func hostsPath() {
        #expect([HostRoute.loginShell].hidesTabBar)
        #expect(![HostRoute.notifications, .add, .edit(UUID())].hidesTabBar)
    }

    static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    @Test("tab bar 的隱藏只在一處(路徑擁有者的堆疊根),不掛在被推入的頁面上")
    func singleSeam() throws {
        let urls = try FileManager.default.contentsOfDirectory(at: Self.featuresFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(urls.count > 10)
        var owners: [String] = []
        for url in urls {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("hidesTabBarWhenCompact"), "\(url.lastPathComponent) 還在被推入的頁面上隱藏 tab bar")
            // 不靠單一字面寫法:有 `toolbarVisibility(`/`.toolbar(` 又出現 `.tabBar` 的檔案都算。
            let setsVisibility = text.contains("toolbarVisibility(") || text.contains(".toolbar(.hidden") || text.contains(".toolbar(.visible")
            if setsVisibility, text.contains(".tabBar") { owners.append(url.lastPathComponent) }
        }
        #expect(owners == ["TopLevelTabs.swift"], "隱藏 tab bar 的 toolbarVisibility 只該在共用 modifier 裡:\(owners)")
    }
}
