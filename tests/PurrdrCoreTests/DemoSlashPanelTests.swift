import Foundation
import PurrdrCore
import PurrdrDemo
import Testing

/// Demo 主機的 slash 面板情境(#45):ledger 送出 `/model` 後畫面開出模型面板，以方向鍵與動作鍵操作。
@Suite("Demo 主機:slash 面板")
struct DemoSlashPanelTests {
    static func panel(on host: DemoHost) async throws -> SlashPanel? {
        SlashPanelParser.parse(screen: try await HerdrClient(channel: host).readPane(paneID: "w1:p1"), agentKind: "claude")
    }

    @Test("/model 開出面板(狀態仍是完成、不寫進對話紀錄);方向鍵移動游標，Enter 選定並關閉;數字不算")
    func modelPanel() async throws {
        let host = DemoHost()
        let client = HerdrClient(channel: host)
        #expect(try await Self.panel(on: host) == nil)

        _ = try await client.prompt(target: "w1:p1", text: "/model", wait: nil)
        let panel = try #require(try await Self.panel(on: host))
        #expect(panel.title == "Select model")
        #expect(panel.options.first { $0.isCurrent }?.index == 1)
        #expect(panel.options.first { $0.isCursor }?.index == 1)
        #expect(try await client.snapshot().agents.first { $0.paneID == "w1:p1" }?.status == .done)

        try await client.sendKeys(paneID: "w1:p1", keys: ["1"])
        #expect(try await Self.panel(on: host)?.options.first { $0.isCurrent }?.index == 1)

        try await client.sendKeys(paneID: "w1:p1", keys: ["up"])
        try await client.sendKeys(paneID: "w1:p1", keys: ["right"])
        let moved = try #require(try await Self.panel(on: host))
        #expect(moved.options.first { $0.isCursor }?.index == 0)
        #expect(moved.adjustment == "◐ High effort")

        try await client.sendKeys(paneID: "w1:p1", keys: ["enter"])
        #expect(try await Self.panel(on: host) == nil)

        _ = try await client.prompt(target: "w1:p1", text: "/model", wait: nil)
        #expect(try await Self.panel(on: host)?.options.first { $0.isCurrent }?.index == 0)
        try await client.sendKeys(paneID: "w1:p1", keys: ["esc"])
        #expect(try await Self.panel(on: host) == nil)
    }
}
