import Foundation
import PurrdrCore

/// 經主機服務送測試通知(#328、raychiutw/purrdr.host#60):`push.test`(主機服務 0.11.0 起)。
/// 只送給這支裝置，不經主機外掛與 herdr;錯誤與 SSH 路線共用 `PushTestNotificationError`。
public struct HostServicePushTestNotifier: Sendable {
    let connection: HTTPSHostConnection
    let deviceID: PushDeviceID
    let hostName: String?

    public init(connection: HTTPSHostConnection, deviceID: PushDeviceID, hostName: String?) {
        self.connection = connection
        self.deviceID = deviceID
        self.hostName = hostName
    }

    public func send() async throws {
        try await connection.requireHostService(.pushTest)
        let deviceID = deviceID.rawValue
        let name = PushTestHostName.sanitized(hostName)
        let connection = connection
        let reply = try await connection.withDeadline(HostCommandDeadline.standard) {
            try await connection.sendKeepingErrors { .pushTest(.init(requestId: $0, deviceId: deviceID, hostName: name)) }
        }
        switch reply {
        case .pushTestResult: return
        case .errorMessage(let error):
            switch error.code {
            case .pushNotPaired: throw PushTestNotificationError.notPaired
            case .pushSendFailed: throw PushTestNotificationError(errorCode: error.message) ?? .failed(error.message)
            default: throw HTTPSHostConnection.error(for: error)
            }
        default: throw HostServiceError.unexpectedResponse
        }
    }
}
