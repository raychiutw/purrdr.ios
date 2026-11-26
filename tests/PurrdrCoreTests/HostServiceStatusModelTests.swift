import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrHTTPS
import Synchronization
import Testing

/// 主機頁(ⓘ)的主機服務區塊(#290):經假主機服務 WebSocket 驗模型的狀態與送出的訊息。
@MainActor
@Suite("主機頁：主機服務")
struct HostServiceStatusModelTests {
    /// 0.7.0、有新版 0.7.1;上次(較早)試過 0.7.1 已退回。
    nonisolated static let outdated = #"""
        {"type":"host_service.status.result","installed_version":"0.7.0","latest_version":"0.7.1","update_available":true,"auto_update":true,
         "last_update":{"checked_at":"2026-11-19T09:00:00Z","result":"update failed: 0.7.0 was put back"},"rolled_back":"0.7.1"}
        """#
    /// 這次更新到 0.7.1 起不來、換回 0.7.0。
    nonisolated static let rolledBack = #"""
        {"type":"host_service.status.result","installed_version":"0.7.0","latest_version":"0.7.1","update_available":true,"auto_update":true,
         "last_update":{"checked_at":"2026-11-20T09:00:00Z","result":"update failed: 0.7.0 was put back"},"rolled_back":"0.7.1"}
        """#
    nonisolated static let current = #"""
        {"type":"host_service.status.result","installed_version":"0.7.1","latest_version":"0.7.1","update_available":false,"auto_update":true,
         "last_update":{"checked_at":"2026-11-20T09:00:00Z","result":"updated 0.7.0 -> 0.7.1"}}
        """#
    /// `host_service.update` 回 0.7.0 → 0.7.1。
    nonisolated static let started = #"""
        {"type":"host_service.update.result","outcome":"started","from_version":"0.7.0","to_version":"0.7.1"}
        """#

    private static func start(
        token: String = "token-ok", _ change: @escaping @Sendable (inout FakeHostService.Settings) -> Void = { _ in }
    ) async throws -> FakeHostService {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.7.0"))
        service.update {
            $0.hostServiceStatusReply = Self.outdated
            $0.hostServiceUpdateReply = Self.started
            change(&$0)
        }
        return service
    }

    /// `onSleep` 在每次等待時呼叫(第幾次)——模擬主機服務在這段時間重啟。
    private static func model(
        _ service: FakeHostService, token: String = "token-ok", restartLimit: Duration = .seconds(9),
        onSleep: @escaping @Sendable (Int) -> Void = { _ in }
    ) -> HostServiceStatusModel {
        let connection = HTTPSHostConnection(address: service.address, deviceToken: { token })
        let sleeps = SleepCounter()
        return HostServiceStatusModel(
            connection: connection,
            sleep: { _ in onSleep(sleeps.next()) },
            restartPollInterval: .seconds(3), restartLimit: restartLimit)
    }

    @Test("出現時讀狀態：版本、新版、自動更新;可更新")
    func showsStatus() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let model = Self.model(service)

        await model.refresh()

        guard case .loaded(let status) = model.content else { Issue.record("沒有讀到狀態"); return }
        #expect(status.installedVersion == "0.7.0")
        #expect(status.latestVersion == "0.7.1")
        #expect(status.autoUpdate)
        #expect(model.canUpdate)
        #expect(!model.isReadOnly)
    }

    @Test("立即更新：主機服務重啟成新版本後重新連線，以 welcome 的版本顯示成功")
    func updateSucceeds() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let model = Self.model(service) { attempt in
            // 第一次重新連線時舊版還在跑(上次的退回紀錄不算這次);第二次前才換好新版。
            if attempt == 2 {
                service.update {
                    $0.hostServiceVersion = "0.7.1"
                    $0.hostServiceStatusReply = Self.current
                }
            }
        }
        await model.refresh()

        await model.updateNow()

        #expect(service.messages(ofType: "host_service.update").count == 1)
        #expect(model.update == .succeeded(version: "0.7.1"))
        guard case .loaded(let status) = model.content else { Issue.record("沒有重讀狀態"); return }
        #expect(status.installedVersion == "0.7.1")
        #expect(!model.canUpdate)
    }

    @Test("立即更新後新版起不來：重新連線仍是舊版、狀態出現這次的退回，顯示已退回")
    func updateRolledBack() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let model = Self.model(service) { attempt in
            if attempt == 1 { service.update { $0.hostServiceStatusReply = Self.rolledBack } }
        }
        await model.refresh()

        await model.updateNow()

        #expect(model.update == .rolledBack(version: "0.7.1", runningVersion: "0.7.0"))
    }

    @Test("時間內沒等到新版也沒看到這次的退回：顯示無法確認")
    func updateUnconfirmed() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let model = Self.model(service)
        await model.refresh()

        await model.updateNow()

        #expect(model.update == .unconfirmed(to: "0.7.1"))
    }

    @Test("無法確認後下拉重新整理：重讀狀態，主機已是新版就顯示成功")
    func refreshAfterUnconfirmedShowsSuccess() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let model = Self.model(service)
        await model.refresh()
        await model.updateNow()
        service.update {
            $0.hostServiceVersion = "0.7.1"
            $0.hostServiceStatusReply = Self.current
        }

        await model.refresh()

        guard case .loaded(let status) = model.content else { Issue.record("沒有重讀狀態"); return }
        #expect(status.installedVersion == "0.7.1")
        #expect(model.update == .succeeded(version: "0.7.1"))
    }

    @Test("無法確認後下拉重新整理：主機仍是舊版就維持無法確認")
    func refreshAfterUnconfirmedKeepsUnconfirmedOnOldVersion() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let model = Self.model(service)
        await model.refresh()
        await model.updateNow()

        await model.refresh()

        #expect(model.update == .unconfirmed(to: "0.7.1"))
    }

    @Test("已有更新在進行：顯示進行中，不等待重新連線")
    func updateInProgress() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let model = Self.model(service)
        await model.refresh()
        service.update { $0.hostServiceErrorCode = "update_in_progress" }

        await model.updateNow()

        guard case .failed(let message) = model.update else { Issue.record("沒有失敗"); return }
        #expect(message.text.contains("already in progress"))
        #expect(service.log.connections == 1)
    }

    @Test("開關自動更新：送出新的開關，畫面顯示主機回報的值")
    func toggleAutoUpdate() async throws {
        let service = try await Self.start()
        defer { Task { await service.stop() } }
        let model = Self.model(service)
        await model.refresh()

        await model.setAutoUpdate(false)

        #expect(service.messages(ofType: "host_service.set_auto_update").first?["enabled"] as? Bool == false)
        guard case .loaded(let status) = model.content else { Issue.record("沒有狀態"); return }
        #expect(status.autoUpdate == false)
        #expect(model.autoUpdateError == nil)
    }

    @Test("唯讀裝置：看得到狀態，更新與自動更新停用、不送出")
    func readOnlyDevice() async throws {
        let service = try await Self.start { $0.readOnlyTokens = ["token-ok"] }
        defer { Task { await service.stop() } }
        let model = Self.model(service)

        await model.refresh()
        await model.updateNow()
        await model.setAutoUpdate(false)

        #expect(model.isReadOnly)
        #expect(!model.canUpdate)
        #expect(!model.canChangeSettings)
        #expect(service.messages(ofType: "host_service.update").isEmpty)
        #expect(service.messages(ofType: "host_service.set_auto_update").isEmpty)
    }

    @Test("主機服務太舊：說明要先更新主機服務，帶已安裝的版本")
    func olderHostService() async throws {
        let service = try await Self.start { $0.hostServiceVersion = "0.6.0" }
        defer { Task { await service.stop() } }
        let model = Self.model(service)

        await model.refresh()

        #expect(model.content == .needsNewerHostService(installedVersion: "0.6.0"))
        #expect(!model.canUpdate)
    }

    @Test("跑的不是安裝好的主機服務：說明不能從 app 管理")
    func notInstalledCopy() async throws {
        let service = try await Self.start { $0.hostServiceErrorCode = "host_service_not_installed" }
        defer { Task { await service.stop() } }
        let model = Self.model(service)

        await model.refresh()

        #expect(model.content == .notInstalledCopy)
    }
}

/// 數等待了幾次(假時鐘)。
private final class SleepCounter: Sendable {
    private let count = Mutex(0)

    func next() -> Int {
        count.withLock {
            $0 += 1
            return $0
        }
    }
}
