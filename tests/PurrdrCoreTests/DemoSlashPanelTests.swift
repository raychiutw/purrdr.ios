import Foundation
import PurrdrCore
import PurrdrDemo
import Testing

/// Demo 主機的 slash 面板情境(#45、#34):ledger 送出 `/model`、`/effort` 後畫面開出面板，以方向鍵與動作鍵操作。
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

    @Test("/effort 開出 effort 滑桿面板(狀態仍是完成、不寫進對話紀錄);←/→ 移動層級，Enter 確認並關閉，Esc 取消")
    func effortPanel() async throws {
        let host = DemoHost()
        let client = HerdrClient(channel: host)
        let before = try await client.snapshot().agents.first { $0.paneID == "w1:p1" }

        _ = try await client.prompt(target: "w1:p1", text: "/effort", wait: nil)
        let panel = try #require(try await Self.panel(on: host))
        #expect(panel.title == "Effort")
        #expect(panel.options.isEmpty)
        #expect(panel.slider == SlashPanelSlider(levels: ["low", "medium", "high", "xhigh", "max"], current: 1))
        #expect(panel.adjustment != nil)
        #expect(panel.actions.map(\.key) == ["enter", "esc"])
        #expect(try await client.snapshot().agents.first { $0.paneID == "w1:p1" }?.status == before?.status)

        // 卡片點「xhigh」:從目前層級送 right × 2(SlashPanel.keys)。
        try await client.sendKeys(paneID: "w1:p1", keys: try #require(panel.keys(for: .level(3))))
        #expect(try await Self.panel(on: host)?.slider?.current == 3)
        try await client.sendKeys(paneID: "w1:p1", keys: ["left"])
        #expect(try await Self.panel(on: host)?.slider?.current == 2)

        try await client.sendKeys(paneID: "w1:p1", keys: ["enter"])
        #expect(try await Self.panel(on: host) == nil)

        // 再開一次：記得上次確認的層級;Esc 取消不改。
        _ = try await client.prompt(target: "w1:p1", text: "/effort", wait: nil)
        #expect(try await Self.panel(on: host)?.slider?.current == 2)
        try await client.sendKeys(paneID: "w1:p1", keys: ["right", "esc"])
        #expect(try await Self.panel(on: host) == nil)
        _ = try await client.prompt(target: "w1:p1", text: "/effort", wait: nil)
        #expect(try await Self.panel(on: host)?.slider?.current == 2)
    }
}
