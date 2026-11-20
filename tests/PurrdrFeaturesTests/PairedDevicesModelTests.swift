import Foundation
import PurrdrCore
import PurrdrFeatures
import Synchronization
import Testing

/// 主機頁(ⓘ)的已配對裝置(#291):列出、撤銷前確認、唯讀裝置只能看、這支裝置不在這裡撤銷。
@MainActor
@Suite("已配對裝置")
struct PairedDevicesModelTests {
    static let thisPhone = PairedDeviceRecord(
        id: "3f9a1c0e7b2d4a58", name: "Ray 的 iPhone", isReadOnly: false, pairedAt: Date(timeIntervalSince1970: 1_793_521_800),
        isCurrentDevice: true)
    static let iPad = PairedDeviceRecord(
        id: "a07c55e19d3b6f21", name: "Ray 的 iPad", isReadOnly: true, pairedAt: Date(timeIntervalSince1970: 1_794_312_005),
        isCurrentDevice: false)

    @Test("載入後列出主機回報的裝置")
    func loadListsDevices() async {
        let host = FakePairedDevicesHost(devices: [Self.thisPhone, Self.iPad])
        let model = PairedDevicesModel(host: host)

        await model.load()

        #expect(model.state == .loaded([Self.thisPhone, Self.iPad]))
    }

    @Test("讀不到時顯示原因")
    func loadFailureShowsReason() async {
        let host = FakePairedDevicesHost(devices: [], listError: HostServiceError.hostServiceUpdateRequired(.pairedDevices, installedVersion: "0.6.0"))
        let model = PairedDevicesModel(host: host)

        await model.load()

        guard case .failed(let message) = model.state else {
            Issue.record("沒有失敗：\(model.state)")
            return
        }
        #expect(message.contains("0.6.0"))
    }

    @Test("撤銷別支裝置要先確認;確認才送出，之後重新列出")
    func revokeAfterConfirmation() async {
        let host = FakePairedDevicesHost(devices: [Self.thisPhone, Self.iPad])
        let model = PairedDevicesModel(host: host)
        await model.load()

        model.requestRevocation(of: Self.iPad)
        #expect(model.confirmingRevocation == Self.iPad)
        #expect(host.revoked.isEmpty)

        await model.confirmRevocation()

        #expect(host.revoked == [Self.iPad.id])
        #expect(model.confirmingRevocation == nil)
        #expect(model.state == .loaded([Self.thisPhone]))
    }

    @Test("取消確認不送出")
    func cancelDoesNotRevoke() async {
        let host = FakePairedDevicesHost(devices: [Self.thisPhone, Self.iPad])
        let model = PairedDevicesModel(host: host)
        await model.load()

        model.requestRevocation(of: Self.iPad)
        model.cancelRevocation()
        await model.confirmRevocation()

        #expect(host.revoked.isEmpty)
    }

    @Test("這支裝置不能在列表撤銷(沿用移除主機的流程)")
    func currentDeviceCannotBeRevokedHere() async {
        let host = FakePairedDevicesHost(devices: [Self.thisPhone, Self.iPad])
        let model = PairedDevicesModel(host: host)
        await model.load()

        #expect(!model.canRevoke(Self.thisPhone))
        model.requestRevocation(of: Self.thisPhone)
        await model.confirmRevocation()

        #expect(model.confirmingRevocation == nil)
        #expect(host.revoked.isEmpty)
    }

    @Test("這支裝置那列導到移除主機的流程(POST /v1/revoke),不送 devices.revoke;唯讀裝置也可以")
    func currentDeviceRowOpensHostRemoval() async {
        let host = FakePairedDevicesHost(devices: [Self.thisPhone, Self.iPad], isReadOnly: true)
        let removals = RemovalCounter()
        let model = PairedDevicesModel(host: host) { removals.count += 1 }
        await model.load()

        #expect(model.canRemoveHost(from: Self.thisPhone))
        #expect(!model.canRemoveHost(from: Self.iPad))
        model.requestHostRemoval(from: Self.iPad)
        model.requestHostRemoval(from: Self.thisPhone)

        #expect(removals.count == 1)
        #expect(host.revoked.isEmpty)
    }

    @Test("沒有移除主機的入口(例如新增主機時):這支裝置那列沒有動作")
    func currentDeviceRowWithoutRemovalHasNoAction() async {
        let model = PairedDevicesModel(host: FakePairedDevicesHost(devices: [Self.thisPhone]))
        await model.load()

        #expect(!model.canRemoveHost(from: Self.thisPhone))
    }

    @Test("唯讀裝置只能看：不能撤銷任何裝置")
    func readOnlyDeviceOnlyViews() async {
        let host = FakePairedDevicesHost(devices: [Self.thisPhone, Self.iPad], isReadOnly: true)
        let model = PairedDevicesModel(host: host)
        await model.load()

        #expect(model.isReadOnly)
        #expect(!model.canRevoke(Self.iPad))
        model.requestRevocation(of: Self.iPad)
        await model.confirmRevocation()

        #expect(host.revoked.isEmpty)
    }

    @Test("撤銷失敗：顯示原因，列表不變")
    func revokeFailureShowsReason() async {
        let host = FakePairedDevicesHost(devices: [Self.thisPhone, Self.iPad], revokeError: HostServiceError.deviceUnknown)
        let model = PairedDevicesModel(host: host)
        await model.load()

        model.requestRevocation(of: Self.iPad)
        await model.confirmRevocation()

        #expect(model.revocationError != nil)
        #expect(model.state == .loaded([Self.thisPhone, Self.iPad]))
    }
}

/// 主機服務的已配對裝置替身：撤銷後從列表拿掉。
private final class FakePairedDevicesHost: PairedDevicesManaging {
    private let state: Mutex<(devices: [PairedDeviceRecord], revoked: [String])>
    private let listError: (any Error & Sendable)?
    private let revokeError: (any Error & Sendable)?
    private let readOnly: Bool

    init(devices: [PairedDeviceRecord], isReadOnly: Bool = false, listError: (any Error & Sendable)? = nil, revokeError: (any Error & Sendable)? = nil) {
        state = Mutex((devices, []))
        readOnly = isReadOnly
        self.listError = listError
        self.revokeError = revokeError
    }

    var revoked: [String] { state.withLock { $0.revoked } }

    func pairedDevices() async throws -> [PairedDeviceRecord] {
        if let listError { throw listError }
        return state.withLock { $0.devices }
    }

    func revokePairedDevice(_ id: String) async throws {
        if let revokeError { throw revokeError }
        state.withLock {
            $0.revoked.append(id)
            $0.devices.removeAll { $0.id == id }
        }
    }

    func isReadOnlyDevice() async throws -> Bool { readOnly }
}

/// 移除主機入口被叫了幾次。
@MainActor
final class RemovalCounter {
    var count = 0
}
