import Foundation
import PurrdrCore
import PurrdrHTTPS
import Testing

/// 對真實主機服務的整合測試，以環境變數開啟(預設不跑;CI 不跑)。只做唯讀的 herdr 請求。
///
/// ```bash
/// # 先在主機上 `purrdr-host-service pair --address <位址>` 取得配對碼(會在主機上多一台裝置，測完可 `revoke`)
/// PURRDR_HTTPS_HOST=https://my-mac.tailnet.ts.net PURRDR_HTTPS_PAIRING_CODE=K7QM-2XPA \
///   swift test --filter HTTPSRealHostIntegrationTests
/// # 已有裝置權杖時改用 PURRDR_HTTPS_TOKEN=<權杖>;本機直連主機服務(不經 tailscale serve)用 http://127.0.0.1:47820
/// ```
@Suite("HTTPS 真實主機整合測試")
struct HTTPSRealHostIntegrationTests {
    static let environment = ProcessInfo.processInfo.environment

    @Test("配對(或用既有權杖)後經主機服務讀 herdr 版本與 Agent 列表", .enabled(if: environment["PURRDR_HTTPS_HOST"] != nil))
    func realHostService() async throws {
        let environment = Self.environment
        let address = try #require(HostServiceAddress(environment["PURRDR_HTTPS_HOST"] ?? ""), "PURRDR_HTTPS_HOST 不是主機服務位址")
        let token: String
        if let code = environment["PURRDR_HTTPS_PAIRING_CODE"] {
            let paired = try await HostServicePairing().pair(address: address, pairingCode: code, deviceName: "purrdr integration test")
            print("裝置 id:\(paired.deviceID)(測完可在主機上 revoke)")
            token = paired.deviceToken
        } else {
            token = try #require(environment["PURRDR_HTTPS_TOKEN"], "要設 PURRDR_HTTPS_PAIRING_CODE 或 PURRDR_HTTPS_TOKEN")
        }
        let connection = HTTPSHostConnection(address: address, deviceToken: { token }, appVersion: "integration-test")
        let client = HerdrClient(connection: connection)

        let welcome = try await connection.hostServiceInfo()
        let version = try await client.ping()
        let snapshot = try await client.snapshot()
        await connection.disconnect()

        print("主機服務 \(welcome.hostServiceVersion)、herdr \(version)、能力 \(welcome.herdr.capabilities)、\(snapshot.agents.count) 個 Agent")
        #expect(HerdrVersion(version).map { $0 >= HerdrVersion(major: 0, minor: 9, patch: 4) } == true)
        #expect(snapshot.version == version)
        #expect(snapshot.agents.allSatisfy { !$0.paneID.isEmpty && !$0.workspaceID.isEmpty })
    }

    /// 只能指向自建測試 workspace 的 shell pane(會在裡面執行 `echo`):
    /// `PURRDR_HTTPS_TERMINAL_PANE=<pane id>`,權杖用 `PURRDR_HTTPS_TOKEN`(配對碼只能用一次)。
    @Test("Pane 終端機：接上測試 Pane,輸入後畫面出現回顯,release 後 detached",
          .enabled(if: environment["PURRDR_HTTPS_HOST"] != nil && environment["PURRDR_HTTPS_TERMINAL_PANE"] != nil))
    func realPaneTerminal() async throws {
        let environment = Self.environment
        let address = try #require(HostServiceAddress(environment["PURRDR_HTTPS_HOST"] ?? ""))
        let token = try #require(environment["PURRDR_HTTPS_TOKEN"], "要設 PURRDR_HTTPS_TOKEN")
        let pane = try #require(environment["PURRDR_HTTPS_TERMINAL_PANE"])
        let connection = HTTPSHostConnection(address: address, deviceToken: { token }, appVersion: "integration-test")
        let marker = "purrdr-swift-\(Int(Date().timeIntervalSince1970))"

        let terminal = try await PaneTerminalClient(connection: connection).control(target: pane, columns: 80, rows: 24)
        var screen = ""
        var events: [PaneTerminalEvent] = []
        for await event in terminal.events {
            events.append(event)
            guard case .frame(let frame) = event else { break }
            if events.count == 1 { try await terminal.send(bytes: Data("echo \(marker)\r".utf8)) }
            screen += String(decoding: frame.bytes, as: UTF8.self)
            if screen.components(separatedBy: marker).count > 2 { await terminal.release() }
        }
        await connection.disconnect()

        #expect(screen.components(separatedBy: marker).count > 2, "畫面沒有出現回顯")
        #expect(events.last == .closed(.detached))
    }
}
