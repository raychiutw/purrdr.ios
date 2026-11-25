import Foundation
import PurrdrCore
import Testing

/// 重裝清理的判斷(#580):UserDefaults 與 Keychain 各一個標記,只有「Keychain 有、UserDefaults 沒有」才清。
@Suite("重裝偵測")
struct ReinstallGuardTests {
    final class Marker: InstallMarker, @unchecked Sendable {
        private let lock = NSLock()
        private var marked: Bool
        init(marked: Bool) { self.marked = marked }
        var isMarked: Bool { lock.withLock { marked } }
        func mark() { lock.withLock { marked = true } }
    }

    /// 假 Keychain 內容:一台主機設定加一把裝置金鑰,清理時整批清空。
    final class FakeKeychainItems: @unchecked Sendable {
        private let lock = NSLock()
        private var items: Set<String> = ["host.studio", "device-key", "offlineQueue.studio"]
        var contents: Set<String> { lock.withLock { items } }
        func purge() { lock.withLock { items = [] } }
    }

    private static func makeGuard(defaultsMarked: Bool, keychainMarked: Bool) -> (guard: ReinstallGuard, defaults: Marker, keychain: Marker, items: FakeKeychainItems) {
        let defaults = Marker(marked: defaultsMarked)
        let keychain = Marker(marked: keychainMarked)
        let items = FakeKeychainItems()
        let reinstallGuard = ReinstallGuard(defaults: defaults, keychain: keychain) { items.purge() }
        return (reinstallGuard, defaults, keychain, items)
    }

    @Test("升級(兩邊都沒標記、Keychain 有舊版的主機):只寫標記,絕不刪主機與金鑰")
    func upgradeKeepsHosts() {
        let rig = Self.makeGuard(defaultsMarked: false, keychainMarked: false)

        let outcome = rig.guard.run()

        #expect(outcome == .firstLaunch)
        #expect(rig.items.contents == ["host.studio", "device-key", "offlineQueue.studio"])
        #expect(rig.defaults.isMarked)
        #expect(rig.keychain.isMarked)
    }

    @Test("全新安裝(兩邊都沒標記、Keychain 空):只寫標記")
    func freshInstallOnlyMarks() {
        let rig = Self.makeGuard(defaultsMarked: false, keychainMarked: false)
        rig.items.purge()

        let outcome = rig.guard.run()

        #expect(outcome == .firstLaunch)
        #expect(rig.defaults.isMarked)
        #expect(rig.keychain.isMarked)
    }

    @Test("重裝(UserDefaults 沒標記、Keychain 有):清掉殘留,再重寫兩個標記")
    func reinstallPurgesAndRemarks() {
        let rig = Self.makeGuard(defaultsMarked: false, keychainMarked: true)

        let outcome = rig.guard.run()

        #expect(outcome == .reinstalled)
        #expect(rig.items.contents.isEmpty)
        #expect(rig.defaults.isMarked)
        #expect(rig.keychain.isMarked)
    }

    @Test("第二次啟動(兩邊都有標記):什麼都不動")
    func secondLaunchIsNoOp() {
        let rig = Self.makeGuard(defaultsMarked: true, keychainMarked: true)

        let outcome = rig.guard.run()

        #expect(outcome == .normal)
        #expect(rig.items.contents == ["host.studio", "device-key", "offlineQueue.studio"])
    }

    @Test("只有 UserDefaults 有標記(Keychain 標記遺失):補標記,不清資料")
    func missingKeychainMarkerDoesNotPurge() {
        let rig = Self.makeGuard(defaultsMarked: true, keychainMarked: false)

        let outcome = rig.guard.run()

        #expect(outcome == .firstLaunch)
        #expect(rig.items.contents == ["host.studio", "device-key", "offlineQueue.studio"])
        #expect(rig.keychain.isMarked)
    }

    @Test("重裝清理後再啟動一次:不會再清")
    func reinstallThenRelaunch() {
        let rig = Self.makeGuard(defaultsMarked: false, keychainMarked: true)
        rig.guard.run()

        let outcome = rig.guard.run()

        #expect(outcome == .normal)
    }
}
