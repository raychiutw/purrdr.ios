import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import Testing

/// Demo 主機的推播外掛(#246):UI 測試在帳號頁開通知時，主機端的安裝與配對只在記憶體。
@Suite("Demo 主機推播")
struct DemoPushTests {
    static func push(_ host: DemoHost) -> PushHost {
        PushHost(channel: host, herdr: HerdrInstallation(), deviceID: "uitesting", pluginSource: "owner/repo")
    }

    @Test("一開始沒有外掛也沒有配對")
    func startsWithoutPlugin() async throws {
        let inspection = try await Self.push(DemoHost()).inspect()

        #expect(!inspection.pluginInstalled)
        #expect(!inspection.isPaired)
    }

    @Test("配對後外掛已安裝、這支裝置已配對")
    func pairingInstallsPlugin() async throws {
        let host = DemoHost()
        let file = PushPairingFile(endpoint: URL(string: "https://backend.invalid/v1/push")!, key: .generate(), muted: [])

        try await Self.push(host).pair(file)

        let inspection = try await Self.push(host).inspect()
        #expect(inspection.pluginInstalled)
        #expect(inspection.isPaired)
    }
}
