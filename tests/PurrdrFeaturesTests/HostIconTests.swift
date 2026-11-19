import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

#if canImport(AppKit)
import AppKit
#endif

/// 主機圖示(#239):11 種加「無」、名稱與符號、舊值相容，以及主機編輯器的圖示欄位。
@MainActor
@Suite("主機圖示")
struct HostIconTests {
    @Test("11 種加「無」,順序同編輯器格狀選擇;存檔值固定(同步 wire 也用它)")
    func casesAndStoredValues() {
        #expect(HostIcon.allCases.map(\.rawValue) == [
            "desktop", "laptop", "macMini", "rack", "pc", "display", "board", "console", "home", "cloud", "terminal", "none",
        ])
    }

    @Test("每種都有名稱;「無」以外都有主機名稱前的符號，選擇器一律有符號")
    func everyIconHasTitleAndSymbol() {
        #expect(HostIcon.allCases.map(\.title) == [
            "Desktop", "Laptop", "Mac mini", "Rack", "PC", "Display", "Dev Board", "Game Console", "House", "Cloud", "Terminal",
            "None",
        ])
        #expect(HostIcon.allCases.map(\.symbol) == [
            "desktopcomputer", "laptopcomputer", "macmini", "server.rack", "pc", "display", "cpu", "gamecontroller", "house", "cloud",
            "apple.terminal", nil,
        ])
        #expect(HostIcon.noIcon.pickerSymbol == "circle.slash")
        #expect(HostIcon.cloud.pickerSymbol == "cloud")
    }

    #if canImport(AppKit)
    @Test("選擇器用的符號都是系統有的 SF Symbol")
    func pickerSymbolsExist() {
        for icon in HostIcon.allCases {
            #expect(NSImage(systemSymbolName: icon.pickerSymbol, accessibilityDescription: nil) != nil, "\(icon.pickerSymbol)")
        }
    }
    #endif

    @Test("舊值相容：server 讀成機架，不認得的值當沒選過;「無」存得回來")
    func storedValuesAreCompatible() {
        #expect(HostIcon(stored: "server") == .rack)
        #expect(HostIcon(stored: "toaster") == nil)
        let defaults = UserDefaults(suiteName: "HostIconTests.\(UUID())")!
        let store = UserDefaultsHostIconStore(defaults: defaults)
        let host = UUID()

        store.setIcon(.noIcon, for: host)

        #expect(UserDefaultsHostIconStore(defaults: defaults).icon(for: host) == HostIcon.noIcon)
    }

    @Test("編輯器帶出主機目前的圖示;只改圖示不必重新測試連線，儲存後列表立刻換圖示、不改主機設定")
    func editorChangesOnlyIcon() {
        let store = MemoryHostStore()
        store.hosts = [HostsModelTests.studio]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory().make)
        model.load()
        model.setIcon(.laptop, for: HostsModelTests.studio.id)
        let editor = model.makeEditor(editing: HostsModelTests.studio)
        #expect(editor.icon == .laptop)
        #expect(!editor.hasChanges)

        editor.icon = .board

        #expect(editor.hasChanges)
        #expect(editor.changesOnlyIcon)
        #expect(editor.canSave)
        #expect(editor.save() == HostsModelTests.studio)
        #expect(model.icon(for: HostsModelTests.studio.id) == .board)
        #expect(model.rows.first?.icon == .board)
        #expect(store.hosts == [HostsModelTests.studio])
    }

    @Test("同時改了圖示與其他欄位：要測試連線才能儲存")
    func iconWithOtherChangesStillNeedsTest() {
        let store = MemoryHostStore()
        store.hosts = [HostsModelTests.studio]
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory().make)
        model.load()
        let editor = model.makeEditor(editing: HostsModelTests.studio)

        editor.icon = .home
        editor.name = "Office"

        #expect(!editor.changesOnlyIcon)
        #expect(!editor.canSave)
        #expect(editor.save() == nil)
        #expect(model.icon(for: HostsModelTests.studio.id) == .default)
    }

    @Test("新增主機：測試通過儲存後套用選的圖示")
    func newHostSavesChosenIcon() async throws {
        let store = MemoryHostStore()
        let factory = ChannelFactory(await HostEditorModelTests.unverifiedHost(), await HostEditorModelTests.healthyHost())
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: factory.make)
        model.load()
        let editor = model.makeEditor()
        #expect(editor.icon == .default)
        HostEditorModelTests.fill(editor)
        editor.icon = .console
        await editor.test()
        await editor.trustPresentedHostKey()

        let saved = try #require(editor.save())

        #expect(model.icon(for: saved.id) == .console)
    }
}
