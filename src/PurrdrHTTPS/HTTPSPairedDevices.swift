import Foundation
import PurrdrCore

/// 已配對裝置(#291):主機服務的 `devices.list`／`devices.revoke`。主機服務沒有這兩個訊息時丟 `hostServiceUpdateRequired`,不送出。
extension HTTPSHostConnection: PairedDevicesManaging {
    public func pairedDevices() async throws -> [PairedDeviceRecord] {
        try await requireHostService(.pairedDevices)
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.send { .devicesList(.init(requestId: $0)) }
        }
        guard case .devicesListResult(let result) = reply else { throw HostServiceError.unexpectedResponse }
        return try result.devices.map { device in
            guard let pairedAt = try? Date(device.pairedAt, strategy: .iso8601) else { throw HostServiceError.unexpectedResponse }
            return PairedDeviceRecord(
                id: device.deviceId, name: device.name, isReadOnly: device.readOnly, pairedAt: pairedAt, isCurrentDevice: device.current)
        }
    }

    public func revokePairedDevice(_ id: String) async throws {
        try await requireHostService(.pairedDevices)
        let reply = try await withDeadline(HostCommandDeadline.standard) {
            try await self.send { .devicesRevoke(.init(requestId: $0, deviceId: id)) }
        }
        guard case .devicesRevokeResult = reply else { throw HostServiceError.unexpectedResponse }
    }
}
