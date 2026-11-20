import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// 主機頁(ⓘ)的已配對裝置(#291):`HTTPSHostConnection` 以主機服務的 `devices.list`／`devices.revoke` 實作 `PairedDevicesManaging`。
@Suite("HTTPS 主機已配對裝置")
struct HTTPSPairedDevicesTests {
    static let listReply = #"{"type":"devices.list.result","devices":[{"device_id":"3f9a1c0e7b2d4a58","name":"Ray 的 iPhone","read_only":false,"paired_at":"2026-11-01T08:30:00Z","current":true},{"device_id":"a07c55e19d3b6f21","name":"Ray 的 iPad","read_only":true,"paired_at":"2026-11-10T12:00:05Z","current":false}]}"#

    private static func start(_ replies: [String: [String]], hostServiceVersion: String = "0.7.0") async throws -> FakeHostService {
        try await FakeHostService.start(.init(deviceReplies: replies, hostServiceVersion: hostServiceVersion))
    }

    private static func connection(_ service: FakeHostService) -> HTTPSHostConnection {
        HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" })
    }

    @Test("列出已配對裝置：名稱、唯讀、配對時間、是不是這支裝置")
    func listsPairedDevices() async throws {
        let service = try await Self.start(["devices.list": [Self.listReply]])
        defer { Task { await service.stop() } }

        let devices = try await Self.connection(service).pairedDevices()

        #expect(devices == [
            PairedDeviceRecord(
                id: "3f9a1c0e7b2d4a58", name: "Ray 的 iPhone", isReadOnly: false,
                pairedAt: Date(timeIntervalSince1970: 1_793_521_800), isCurrentDevice: true),
            PairedDeviceRecord(
                id: "a07c55e19d3b6f21", name: "Ray 的 iPad", isReadOnly: true,
                pairedAt: Date(timeIntervalSince1970: 1_794_312_005), isCurrentDevice: false),
        ])
    }

    @Test("撤銷送出 devices.revoke 與那支裝置的 id")
    func revokeSendsDeviceID() async throws {
        let service = try await Self.start([
            "devices.revoke": [#"{"type":"devices.revoke.result","device_id":"a07c55e19d3b6f21"}"#],
        ])
        defer { Task { await service.stop() } }

        try await Self.connection(service).revokePairedDevice("a07c55e19d3b6f21")

        let sent = try #require(service.messages(ofType: "devices.revoke").first)
        #expect(sent["device_id"] as? String == "a07c55e19d3b6f21")
    }

    @Test("主機不認得這支裝置：deviceUnknown")
    func unknownDeviceThrowsDeviceUnknown() async throws {
        let service = try await Self.start([
            "devices.revoke": [#"{"type":"error","code":"device_unknown","message":"no paired device has this id"}"#],
        ])
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.deviceUnknown) {
            try await Self.connection(service).revokePairedDevice("0000")
        }
    }

    @Test("0.7.0 之前的主機服務沒有裝置管理：要求更新主機服務，不送出")
    func olderHostServiceRequiresUpdate() async throws {
        let service = try await Self.start([:], hostServiceVersion: "0.6.0")
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.pairedDevices, installedVersion: "0.6.0")) {
            try await Self.connection(service).pairedDevices()
        }
        #expect(service.messages(ofType: "devices.list").isEmpty)
    }
}
