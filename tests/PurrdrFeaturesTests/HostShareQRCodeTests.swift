import Foundation
import PurrdrCore
import PurrdrFeatures
import Testing
import Vision

/// 主機的 QR code:用 Vision 掃回來，內容就是主機分享連結，匯入得回同一台主機，而且沒有祕密。
@MainActor
@Suite("主機 QR code")
struct HostShareQRCodeTests {
    @Test("QR code 掃得出主機分享連結，匯入後是同一台主機")
    func qrCodeScansBackToShareLink() throws {
        let host = HostsModelTests.studio
        let link = HostShareLink.url(for: host)
        let image = try #require(QRCodeImage.make(for: link.absoluteString))

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let payload = try #require(request.results?.first?.payloadStringValue)

        #expect(payload == link.absoluteString)
        #expect(try HostShareLink.decode(try #require(URL(string: payload))) == SharedHost(host))
    }
}
