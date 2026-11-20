import Foundation
import PurrdrCore
import PurrdrHTTPS
import PurrdrSSH
import Testing

/// HTTPS 主機讀 Pane 畫面(#303,主機服務 `pane.read`):提問卡、計畫卡、建議提示詞、slash 面板與即時預覽都靠它，
/// 經假主機服務 WebSocket,從 `HerdrClient` 這一端驗證。
@Suite("HTTPS 主機讀 Pane 畫面")
struct HTTPSPaneReadTests {
    /// 有 `pane.read` 的主機服務版本。
    private static let currentVersion = "0.7.0"
    /// 錄自真實 Claude Code 的選擇題畫面(縮短)。
    private static let menuScreen = "Which storage should the cache use?\n\n❯ 1. JSON file\n  2. SQLite\n\nEnter to select · Esc to cancel\n"

    private static func client(to service: FakeHostService) -> HerdrClient {
        HerdrClient(connection: HTTPSHostConnection(address: service.address, deviceToken: { "token-ok" }, appVersion: "9.9.9"))
    }

    private static func sent(_ service: FakeHostService, type: String) throws -> [String: Any] {
        let messages = service.log.messages.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return try #require(messages.last { $0["type"] as? String == type })
    }

    @Test("讀畫面送 pane.read(pane_id、source visible、不帶 format),回傳主機服務給的畫面文字")
    func readVisibleText() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: Self.currentVersion, paneScreens: ["w1:p6": Self.menuScreen]))
        defer { Task { await service.stop() } }

        let screen = try await Self.client(to: service).readPane(paneID: "w1:p6")

        #expect(screen == Self.menuScreen)
        let sent = try Self.sent(service, type: "pane.read")
        #expect(sent["pane_id"] as? String == "w1:p6")
        #expect(sent["source"] as? String == "visible")
        #expect(sent["format"] == nil)
    }

    @Test("讀含 ANSI 的畫面(建議提示詞):帶 format ansi,文字照原樣回傳")
    func readANSI() async throws {
        let ansi = "\u{1B}[2mTry \"add a test for the cache\"\u{1B}[22m\r\n"
        let service = try await FakeHostService.start(.init(
            hostServiceVersion: Self.currentVersion, paneScreens: ["w1:p6": "plain"], ansiPaneScreens: ["w1:p6": ansi]))
        defer { Task { await service.stop() } }

        let screen = try await Self.client(to: service).readPane(paneID: "w1:p6", format: .ansi)

        #expect(screen == ansi)
        #expect(try Self.sent(service, type: "pane.read")["format"] as? String == "ansi")
    }

    @Test("herdr 找不到 pane:herdr 的碼原樣回報")
    func paneNotFound() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: Self.currentVersion))
        defer { Task { await service.stop() } }

        await #expect {
            _ = try await Self.client(to: service).readPane(paneID: "w9:p9")
        } throws: { error in
            if case HerdrError.herdr(code: "pane_not_found", _) = error { return true }
            return false
        }
    }

    @Test("主機服務版本不足：不送出，回「需要更新主機服務」的專屬錯誤")
    func olderHostServiceRequiresUpdate() async throws {
        let service = try await FakeHostService.start(.init(hostServiceVersion: "0.6.0", paneScreens: ["w1:p6": Self.menuScreen]))
        defer { Task { await service.stop() } }

        await #expect(throws: HostServiceError.hostServiceUpdateRequired(.paneRead, installedVersion: "0.6.0")) {
            _ = try await Self.client(to: service).readPane(paneID: "w1:p6")
        }
        #expect(!service.log.messages.contains { $0.contains("pane.read") })
    }

    @Test("唯讀裝置也能讀畫面(pane.read 不是寫入類)")
    func readOnlyDeviceCanRead() async throws {
        let service = try await FakeHostService.start(.init(
            readOnlyTokens: ["token-ok"], hostServiceVersion: Self.currentVersion, paneScreens: ["w1:p6": Self.menuScreen]))
        defer { Task { await service.stop() } }

        #expect(try await Self.client(to: service).readPane(paneID: "w1:p6") == Self.menuScreen)
    }
}
