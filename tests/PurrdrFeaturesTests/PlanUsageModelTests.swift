#if os(macOS)
import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 方案用量畫面(#177):選主機與 Agent 後查詢。主機是本機 `/bin/sh` + 暫存家目錄(LocalShellHost)。
@MainActor
@Suite("方案用量畫面")
struct PlanUsageModelTests {
    static let settings = #"{"statusLine":{"type":"command","command":"~/.claude/statusline.sh"}}"#
    static let mac = HostSelection.host(UUID(uuidString: "6F1C2A4E-0B7D-4C1E-9A55-0D2C8E1F3A10")!)
    static let linux = HostSelection.host(UUID(uuidString: "1A2B3C4D-5E6F-4A1B-8C2D-3E4F5A6B7C8D")!)
    static let now = Date(timeIntervalSince1970: 1_738_400_000)

    let host: LocalShellHost
    let consent = InMemoryHostWriteConsentStore()

    init() throws {
        host = try LocalShellHost.temporary()
        try host.write(Data(Self.settings.utf8), to: ".claude/settings.json")
    }

    /// 模擬 Claude Code 執行了包裝腳本、存下用量。
    func claudeReportsUsage(fiveHour: Double = 23.5, week: Double = 41.2, capturedAt: Int = 1_738_399_900) throws {
        try host.write(Data(#"{"captured_at":\#(capturedAt),"status_line_input":{"rate_limits":{"five_hour":{"used_percentage":\#(fiveHour),"resets_at":1738425600},"seven_day":{"used_percentage":\#(week),"resets_at":1738857600}}}}"#.utf8),
                       to: ".purrdr/claude-usage/usage.json")
    }

    func grantClaudeUsage(on selection: HostSelection = Self.mac) {
        consent.grant(ClaudeUsageHost.feature.id, host: selection.storedValue)
    }

    func model(
        channel: (any HostChannel)? = nil, cost: PlanUsageQueryCost = .transfer
    ) -> PlanUsageModel {
        let channel = channel ?? host
        let consent = consent
        return PlanUsageModel(
            hosts: [PlanUsageHostOption(id: Self.mac, name: "Mac"), PlanUsageHostOption(id: Self.linux, name: "Linux")],
            fallback: Self.mac, now: { Self.now }
        ) { selection, _ in
            .claude(channel: channel, cost: cost, hostID: selection.storedValue, consent: consent)
        }
    }

    @Test("打開畫面：依選擇查一次，顯示 5 小時與每週用量週期")
    func appearingQueriesOnce() async throws {
        grantClaudeUsage()
        try claudeReportsUsage()
        let model = model()

        model.appeared()
        await model.untilIdle()

        #expect(model.rows.map(\.period) == [.fiveHour, .week])
        #expect(model.rows.map(\.percent) == [77, 59])
        #expect(host.commands.count == 1)
    }
}
#endif
