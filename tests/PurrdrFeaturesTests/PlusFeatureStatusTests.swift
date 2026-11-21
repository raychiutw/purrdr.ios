import Testing
@testable import PurrdrFeatures

/// Purrdr Plus 頁「你的 Plus 包含」功能列尾的目前狀態(#323)。
struct PlusFeatureStatusTests {
    @Test("通知列尾是開啟通知的主機數，沒有主機時是關閉")
    func notificationsValue() {
        #expect(PlusFeatureStatus(notifyingHostCount: 2, isHostSyncOn: false, deviceCount: nil).value(for: .notifications) == "2 computers")
        #expect(PlusFeatureStatus(notifyingHostCount: 0, isHostSyncOn: false, deviceCount: nil).value(for: .notifications) == "Off")
    }

    @Test("主機同步列尾是開啟或關閉")
    func hostSyncValue() {
        #expect(PlusFeatureStatus(notifyingHostCount: 0, isHostSyncOn: true, deviceCount: nil).value(for: .hostSync) == "On")
        #expect(PlusFeatureStatus(notifyingHostCount: 0, isHostSyncOn: false, deviceCount: nil).value(for: .hostSync) == "Off")
    }

    @Test("通知裝置列尾是支數，還沒讀到清單時不顯示")
    func devicesValue() {
        #expect(PlusFeatureStatus(notifyingHostCount: 0, isHostSyncOn: false, deviceCount: 2).value(for: .devices) == "2 devices")
        #expect(PlusFeatureStatus(notifyingHostCount: 0, isHostSyncOn: false, deviceCount: nil).value(for: .devices) == nil)
    }
}
