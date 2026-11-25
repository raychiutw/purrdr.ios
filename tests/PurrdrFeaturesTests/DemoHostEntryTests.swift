import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 範例主機的入口與移除(#394):啟用後才出現在各主機選單,可隨時移除。
@MainActor
@Suite("範例主機入口與移除")
struct DemoHostEntryTests {
    static func model(saved: [HostConfiguration] = []) -> HostsModel {
        let store = MemoryHostStore()
        store.hosts = saved
        let model = HostsModel(store: store, demoChannel: FakeHost(), makeChannel: ChannelFactory(FakeHost()).make)
        model.load()
        return model
    }

    @Test("還沒啟用範例主機:各主機選單都不列它;啟用後才出現")
    func pickersListDemoOnlyAfterEntering() {
        let model = Self.model(saved: [HostsModelTests.studio])
        model.demoEntered = false

        #expect(!model.screens.selectedHostPicker().options.contains { $0.id == .demo })
        #expect(!model.screens.newChatHostPicker().options.contains { $0.id == .demo })

        model.enterDemo()

        #expect(model.screens.selectedHostPicker().options.contains { $0.id == .demo })
        #expect(model.screens.newChatHostPicker().options.contains { $0.id == .demo })
    }

    @Test("移除範例主機:選取中主機回到已存主機,選單不再列它")
    func removingDemoFallsBackToSavedHost() {
        let model = Self.model(saved: [HostsModelTests.studio])
        model.enterDemo()
        #expect(model.selection == .demo)

        model.removeDemo()

        #expect(!model.demoEntered)
        #expect(model.selection == .host(HostsModelTests.studio.id))
        #expect(!model.screens.selectedHostPicker().options.contains { $0.id == .demo })
    }

    @Test("沒有其他主機時移除範例主機:回到沒有主機的空狀態")
    func removingDemoWithoutHostsShowsEmptyState() {
        let model = Self.model()
        model.enterDemo()
        #expect(!model.hasNoHostToShow)

        model.removeDemo()

        #expect(model.hasNoHostToShow)
    }

    @Test("啟用與移除會通知記錄的地方(重開 app 後保持)")
    func reportsChanges() {
        let model = Self.model()
        model.demoEntered = false
        var reported: [Bool] = []
        model.demoEnteredDidChange = { reported.append($0) }

        model.enterDemo()
        model.removeDemo()

        #expect(reported == [true, false])
    }
}
