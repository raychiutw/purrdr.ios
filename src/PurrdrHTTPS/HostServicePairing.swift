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
        let body = try JSONEncoder().encode(HostServiceProtocol.PairRequest(pairingCode: pairingCode, deviceName: deviceName))
        let response = try await http.post(address.pairURL, bearerToken: nil, body: body)
        guard response.status == 200 else { throw Self.error(from: response) }
        guard let paired = try? JSONDecoder().decode(HostServiceProtocol.PairResponse.self, from: response.body) else {
            throw HostServiceError.unexpectedResponse
        }
        return PairedDevice(deviceID: paired.deviceId, deviceToken: paired.deviceToken, readOnly: paired.readOnly)
    }

    /// 請主機服務撤銷這支裝置的權杖(刪除主機時)。權杖已失效也算成功。
    public func revoke(address: HostServiceAddress, deviceToken: String) async throws {
        let response = try await http.post(address.revokeURL, bearerToken: deviceToken, body: nil)
        guard (200..<300).contains(response.status) else {
            let error = Self.error(from: response)
            if (error as? HostServiceError)?.requiresPairing == true { return }
            throw error
        }
    }

    private static func error(from response: HostServiceHTTPResponse) -> any Error {
        guard let message = try? JSONDecoder().decode(HostServiceProtocol.ServerMessage.self, from: response.body),
              case .errorMessage(let error) = message
        else { return HostServiceError.unexpectedResponse }
        return HTTPSHostConnection.error(for: error)
    }
}
