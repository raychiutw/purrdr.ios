import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// HTTPS 主機的測試通知(raychiutw/purrdr.host#60):`push.test`(主機服務 0.11.0 起)。
@Suite("主機服務的測試通知")
struct HostServicePushTestTests {
    static let deviceID = PushDeviceID(rawValue: "aaaaaaaaaaaaaaaa")!

    private static func installer(_ service: FakeHostService, token: String = "token-ok") -> HostServicePushPluginInstaller {
        HostServicePushPluginInstaller(
            connection: HTTPSHostConnection(address: service.address, deviceToken: { token }), deviceID: deviceID)
    }

    @Test("送出裝置 id 與清理過的電腦名稱,成功就回來")
    func sendsDeviceAndHostName() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.11.0"))
        defer { Task { await service.stop() } }

        try await Self.installer(service).sendTestNotification(hostName: "Studio\u{7}Mac")

        let sent = try #require(service.messages(ofType: "push.test").first)
        #expect(sent["device_id"] as? String == Self.deviceID.rawValue)
        #expect(sent["host_name"] as? String == "StudioMac")
    }

    @Test("名稱是空的就不送 host_name")
    func omitsEmptyHostName() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.11.0"))
        defer { Task { await service.stop() } }

        try await Self.installer(service).sendTestNotification(hostName: " \n ")

        let sent = try #require(service.messages(ofType: "push.test").first)
        #expect(sent["host_name"] == nil)
    }

    @Test("主機服務 0.10.0:不送出,回報要更新")
    func outdatedHostService() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.10.0"))
        defer { Task { await service.stop() } }

        await #expect(throws: PushTestError.hostServiceOutdated(installed: "0.10.0")) {
            try await Self.installer(service).sendTestNotification(hostName: nil)
        }
        #expect(service.messages(ofType: "push.test").isEmpty)
    }

    @Test("沒有配對、後台的錯誤碼各對應專屬錯誤")
    func errorsMapToTestErrors() async throws {
        let cases: [(String?, PushTestError)] = [
            (nil, .notPaired), ("subscription_required", .subscriptionRequired), ("rate_limited", .rateLimited),
            ("apns_failed", .deliveryFailed("apns_failed")), ("http 502", .deliveryFailed("http 502")),
        ]
        for (failure, expected) in cases {
            let service = try await FakeHostService.start(.init(hostServiceVersion: "0.11.0", pushTestFailure: failure, pushTestPaired: failure != nil))
            defer { Task { await service.stop() } }
            await #expect(throws: expected) {
                try await Self.installer(service).sendTestNotification(hostName: "Mac")
            }
        }
    }

    @Test("唯讀裝置被拒:readOnlyDevice")
    func readOnlyDeviceIsRejected() async throws {
        let service = try await FakeHostService.start(.init(readOnlyTokens: ["token-ok"], hostServiceVersion: "0.11.0"))
        defer { Task { await service.stop() } }

        await #expect(throws: PushTestError.readOnlyDevice) {
            try await Self.installer(service).sendTestNotification(hostName: "Mac")
        }
    }
}

@Suite("測試通知的電腦名稱")
struct PushTestHostNameTests {
    @Test("去掉控制字元與頭尾空白,超過 64 個字截斷(以 code point 計),空的是 nil")
    func sanitizes() {
        #expect(PushTestHostName.sanitized("  Studio Mac \n") == "Studio Mac")
        #expect(PushTestHostName.sanitized("A\u{0}B\u{1B}C") == "ABC")
        #expect(PushTestHostName.sanitized(String(repeating: "電", count: 80)) == String(repeating: "電", count: 64))
        #expect(PushTestHostName.sanitized("\n\t") == nil)
        #expect(PushTestHostName.sanitized(nil) == nil)
    }
}
