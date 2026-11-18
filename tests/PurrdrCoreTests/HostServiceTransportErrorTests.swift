import Foundation
import PurrdrCore
@testable import PurrdrHTTPS
import Testing

/// 連線層錯誤換成畫面說明的種類(#58):分辨「這支裝置不在 tailnet」與「主機離線」。
@Suite("HTTPS 連線錯誤種類")
struct HostServiceTransportErrorTests {
    @Test(
        "MagicDNS 名稱查不到：這支裝置不在 tailnet(MagicDNS 名稱只在 tailnet 內解析得到)",
        arguments: [URLError.Code.cannotFindHost, .dnsLookupFailed])
    func magicDNSLookupFailureMeansNotOnTailnet(code: URLError.Code) {
        let error = URLSessionHostServiceTransport.hostServiceError(URLError(code), status: nil, hostName: "studio.tail1234.ts.net")

        #expect(error == .notOnTailnet)
    }

    @Test("這支裝置沒有網路：一樣說明連不到 tailnet")
    func offlineDeviceMeansNotOnTailnet() {
        let error = URLSessionHostServiceTransport.hostServiceError(
            URLError(.notConnectedToInternet), status: nil, hostName: "studio.tail1234.ts.net")

        #expect(error == .notOnTailnet)
    }

    @Test("不是 MagicDNS 的名稱查不到：位址打錯")
    func otherLookupFailureMeansWrongAddress() {
        let error = URLSessionHostServiceTransport.hostServiceError(URLError(.cannotFindHost), status: nil, hostName: "studio.example.com")

        #expect(error == .hostNotFound)
    }

    @Test(
        "名稱解析得到但連不上或逾時：主機離線(不在 tailnet 時 MagicDNS 名稱根本解析不到)",
        arguments: [URLError.Code.timedOut, .cannotConnectToHost])
    func resolvedButSilentMeansHostOffline(code: URLError.Code) {
        let error = URLSessionHostServiceTransport.hostServiceError(URLError(code), status: nil, hostName: "studio.tail1234.ts.net")

        #expect(error == .unreachable)
    }
}
