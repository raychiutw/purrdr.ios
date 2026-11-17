import Foundation
import PurrdrCore

/// 連線配對(`POST /v1/pair`)與撤銷自己的裝置權杖(`POST /v1/revoke`)。
public struct HostServicePairing: Sendable {
    private let http: any HostServiceHTTPSending

    public init(http: any HostServiceHTTPSending = URLSessionHostServiceTransport()) {
        self.http = http
    }

    /// 以配對碼換這台主機的裝置權杖。`deviceName` 顯示在主機的裝置列表。
    public func pair(address: HostServiceAddress, pairingCode: String, deviceName: String) async throws -> PairedDevice {
        throw HostServiceError.unexpectedResponse
    }

    /// 請主機服務撤銷這支裝置的權杖(刪除主機時)。權杖已失效也算成功。
    public func revoke(address: HostServiceAddress, deviceToken: String) async throws {
        throw HostServiceError.unexpectedResponse
    }

    private static func error(from response: HostServiceHTTPResponse) -> any Error {
        guard let message = try? JSONDecoder().decode(HostServiceProtocol.ServerMessage.self, from: response.body),
              case .errorMessage(let error) = message
        else { return HostServiceError.unexpectedResponse }
        return HTTPSHostConnection.error(for: error)
    }
}
