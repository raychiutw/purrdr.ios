import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Tailscale SSH check mode:從 SSH 認證橫幅認出重新驗證的網址。
@Suite("Tailscale SSH check mode 橫幅")
struct TailscaleCheckBannerTests {
    @Test("check mode 的橫幅：取出驗證網址")
    func findsAuthenticationURL() {
        let banner = Fixtures.tailscaleBanner("check-mode.banner.txt")

        #expect(TailscaleCheck.authenticationURL(inBanner: banner) == URL(string: "https://login.tailscale.com/a/1a2b3c4d5e6f7"))
    }

    @Test("一般的登入橫幅(沒有要求驗證)不是 check mode,即使帶了網址")
    func ignoresOtherBanners() {
        #expect(TailscaleCheck.authenticationURL(inBanner: "Authorized use only.\n") == nil)
        #expect(TailscaleCheck.authenticationURL(inBanner: "Usage policy: https://example.com/policy\n") == nil)
    }

    @Test("不是 https 的網址不開(避免被引導到明文或其他 scheme)")
    func requiresHTTPS() {
        #expect(TailscaleCheck.authenticationURL(inBanner: "# To authenticate, visit: http://login.tailscale.com/a/x\n") == nil)
        #expect(TailscaleCheck.authenticationURL(inBanner: "# To authenticate, visit: javascript:alert(1)\n") == nil)
    }
}
