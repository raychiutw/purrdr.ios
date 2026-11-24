import Foundation
import PurrdrFeatures
import Testing

@Suite("帳號頭像掛在哪裡(#520)")
struct AccountButtonPlacementTests {
    @Test("寬視窗的聊天 tab:頭像在最右邊那欄(對話欄)的工具列,列表頂列不放")
    func wideChatsUsesDetailToolbar() {
        #expect(AccountButtonPlacement.host(for: .chats, isWideWindow: true) == .detailToolbar)
    }

    @Test("窄視窗的聊天 tab:收成一疊,頭像回到列表頂列右側(同 iPhone)")
    func narrowChatsUsesListTopBar() {
        #expect(AccountButtonPlacement.host(for: .chats, isWideWindow: false) == .topBar)
    }

    @Test("檔案、主機、流量只有一欄:頂列本身就跨滿視窗,寬窄都在頂列")
    func singleColumnTabsAlwaysUseTopBar() {
        for tab in [TopLevelTab.files, .hosts, .traffic] {
            #expect(AccountButtonPlacement.host(for: tab, isWideWindow: true) == .topBar)
            #expect(AccountButtonPlacement.host(for: tab, isWideWindow: false) == .topBar)
        }
    }

    @Test("同一時間只有一顆:頂列與對話欄工具列互斥")
    func exactlyOneHost() {
        for tab in TopLevelTab.allCases {
            for wide in [true, false] {
                let placement = AccountButtonPlacement.host(for: tab, isWideWindow: wide)
                #expect(AccountButtonPlacement.showsInTopBar(for: tab, isWideWindow: wide) == (placement == .topBar))
                #expect(AccountButtonPlacement.showsInDetailToolbar(for: tab, isWideWindow: wide) == (placement == .detailToolbar))
            }
        }
    }
}
