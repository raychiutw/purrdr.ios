import Foundation
import Testing

@testable import PurrdrFeatures

/// 會員後台的 HTTP 傳輸不讓回應(含權杖)留在 URL 快取(#580)。
@Suite("後台傳輸的 URLSession 設定")
struct URLSessionBackendTransportTests {
    @Test("預設的 session 是 ephemeral:沒有 URL 快取、不看本機快取")
    func defaultSessionDoesNotCache() {
        let configuration = URLSessionBackendTransport.makeSession().configuration

        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.urlCredentialStorage == nil)
    }
}
