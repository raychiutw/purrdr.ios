@testable import PurrdrFeatures
import Testing

/// 聊天列表「⋯」選單的項目與分組(#241、hig-audit 14.1、14.3)。
@Suite("「⋯」選單分組")
struct MoreMenuLayoutTests {
    @Test("新增聊天在第一組，主機工具在中間，設定獨立在最後")
    func groupsNewChatThenHostToolsThenSettings() {
        let groups = MoreMenuItem.groups(supportsShell: true)

        #expect(groups == [
            [.newChat],
            [.hosts, .planUsage, .loginShell, .files],
            [.settings],
        ])
    }

    @Test("主機沒有登入 Shell 時，主機工具組只剩主機與方案用量")
    func hostWithoutShellOmitsLoginShellAndFiles() {
        let groups = MoreMenuItem.groups(supportsShell: false)

        #expect(groups == [
            [.newChat],
            [.hosts, .planUsage],
            [.settings],
        ])
    }

    @Test("選單不再有會員與 Purrdr Plus")
    func memberAndPlusAreNotMenuItems() {
        let identifiers = MoreMenuItem.groups(supportsShell: true).flatMap { $0 }.map(\.accessibilityIdentifier)

        #expect(!identifiers.contains("menu.member"))
        #expect(!identifiers.contains("menu.plus"))
    }

    @Test("UI 測試用的 identifier 沿用既有名稱")
    func accessibilityIdentifiersKeepExistingNames() {
        #expect(MoreMenuItem.newChat.accessibilityIdentifier == "menu.newChat")
        #expect(MoreMenuItem.hosts.accessibilityIdentifier == "menu.hosts")
        #expect(MoreMenuItem.planUsage.accessibilityIdentifier == "menu.planUsage")
        #expect(MoreMenuItem.loginShell.accessibilityIdentifier == "menu.loginShell")
        #expect(MoreMenuItem.files.accessibilityIdentifier == "menu.files")
        #expect(MoreMenuItem.settings.accessibilityIdentifier == "menu.settings")
    }
}
