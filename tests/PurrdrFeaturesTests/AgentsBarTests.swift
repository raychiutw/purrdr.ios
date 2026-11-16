import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 背景 agents 列的讀取時機(行為規格 F10「背景 agents 列」、R-W05)。herdr 走假主機：snapshot 與 `pane.read`
/// 都是錄製的(`pane.read.agents-pane.ndjson` 是作者 Mac 上有背景 agent 在跑的 Claude pane,已去識別化)。
@MainActor
@Suite("背景 agents 列")
struct AgentsBarTests {
    typealias Base = ConversationModelTests
    static let paneRead = "pane.read.agents-pane.ndjson"

    static func snapshot(_ status: String) -> FakeReply {
        Base.snapshot { $0["agent_status"] = status }
    }

    /// 錄製畫面中的窗格，改成全部完成、或整個拿掉(背景 agent 都結束、窗格消失)。
    static func paneRead(_ change: @escaping @Sendable (String) -> String) -> FakeReply {
        .recorded(paneRead) { response in
            var result = response["result"] as? [String: Any] ?? [:]
            var read = result["read"] as? [String: Any] ?? [:]
            read["text"] = change(read["text"] as? String ?? "")
            result["read"] = read
            response["result"] = result
        }
    }

    static func bridgeCount(_ setup: Base.Setup) async -> Int {
        await setup.host.bridge.executions.count
    }

    @Test("工作中：每次輪詢讀畫面，解析出窗格")
    func workingReadsEveryPoll() async throws {
        let setup = try Base.setup()
        await setup.host.bridge.expect(Base.bridge, reply: Self.snapshot("working"))
        await setup.host.bridge.expect(Base.bridge, reply: .recorded(Self.paneRead))

        await setup.model.poll()

        #expect(setup.model.agentsPane?.rows.count == 5)
        #expect(setup.model.agentsPane?.hiddenCount == 4)
        #expect(await Self.bridgeCount(setup) == 2)
    }

    @Test("閒置：沒有窗格、也不是剛從工作中變閒置時不讀畫面")
    func idleWithoutPaneSkipsRead() async throws {
        let setup = try Base.setup()
        await setup.host.bridge.expect(Base.bridge, reply: Self.snapshot("idle"))

        await setup.model.poll()

        #expect(await Self.bridgeCount(setup) == 1)
        #expect(setup.model.agentsPane == nil)
    }

    /// commit e0d34ce:一輪可能在兩次輪詢之間開始背景 agent 並結束。
    @Test("working 後第一次閒置要讀;上次有窗格就繼續讀;窗格消失後閒置不再讀")
    func firstIdleAfterWorkingReads() async throws {
        let setup = try Base.setup()
        await setup.host.bridge.expect(Base.bridge, reply: Self.snapshot("working"))
        await setup.host.bridge.expect(Base.bridge, reply: .recorded(Self.paneRead))
        await setup.host.bridge.expect(Base.bridge, reply: Self.snapshot("idle"))
        await setup.host.bridge.expect(Base.bridge, reply: Self.paneRead { $0.replacingOccurrences(of: "◯", with: "✔") })
        await setup.host.bridge.expect(Base.bridge, reply: Self.snapshot("idle"))
        await setup.host.bridge.expect(Base.bridge, reply: Self.paneRead { $0.components(separatedBy: "  ⏺ main")[0] })
        await setup.host.bridge.expect(Base.bridge, reply: Self.snapshot("idle"))

        await setup.model.poll()
        await setup.model.poll()
        #expect(setup.model.agentsPane?.rows.allSatisfy { $0.state == .completed } == true)
        await setup.model.poll()
        #expect(setup.model.agentsPane == nil)
        await setup.model.poll()

        #expect(await Self.bridgeCount(setup) == 7)
        #expect(await setup.host.bridge.unmetExpectations.isEmpty)
    }

    @Test("問題開著(blocked)時沿用上次的窗格，不讀畫面")
    func blockedKeepsLastPane() async throws {
        let setup = try Base.setup()
        await setup.host.bridge.expect(Base.bridge, reply: Self.snapshot("working"))
        await setup.host.bridge.expect(Base.bridge, reply: .recorded(Self.paneRead))
        await setup.host.bridge.expect(Base.bridge, reply: Self.snapshot("blocked"))

        await setup.model.poll()
        await setup.model.poll()

        #expect(setup.model.agentsPane?.rows.count == 5)
        #expect(await Self.bridgeCount(setup) == 3)
    }

    /// commit 0a3b0d7:herdr 在背景 agent 執行時回報 idle。
    @Test("窗格有執行中的列時維持快速輪詢(即使 herdr 說閒置)")
    func runningRowsKeepFastPolling() async throws {
        let setup = try Base.setup()
        await setup.host.bridge.expect(Base.bridge, reply: Self.snapshot("working"))
        await setup.host.bridge.expect(Base.bridge, reply: .recorded(Self.paneRead))
        await setup.host.bridge.expect(Base.bridge, reply: Self.snapshot("idle"))
        await setup.host.bridge.expect(Base.bridge, reply: .recorded(Self.paneRead))
        await setup.host.bridge.expect(Base.bridge, reply: Self.snapshot("idle"))
        await setup.host.bridge.expect(Base.bridge, reply: Self.paneRead { $0.replacingOccurrences(of: "◯", with: "✔") })

        await setup.model.poll()
        await setup.model.poll()
        #expect(setup.model.agentStatus == .idle)
        #expect(setup.model.pollInterval == .seconds(2))
        await setup.model.poll()
        #expect(setup.model.pollInterval == .seconds(4))
    }

    @Test("任務文字與某張 subagent 卡的描述完全相同的列，可以打開那張卡的對話紀錄")
    func rowMatchesSubagentCard() async throws {
        let setup = try Base.setup(transcript: Fixtures.transcript("delegation.jsonl"))
        await setup.host.bridge.expect(Base.bridge, reply: Self.snapshot("working"))
        await setup.host.bridge.expect(Base.bridge, reply: Self.paneRead {
            $0.replacingOccurrences(of: "Running the full test suite  ", with: "Compare two CSV parsing libraries")
        })

        await setup.model.poll()

        let rows = try #require(setup.model.agentsPane?.rows)
        #expect(setup.model.subagentCard(forTask: rows[1].task)?.callID == "toolu_demo_d01")
        #expect(setup.model.subagentCard(forTask: rows[0].task) == nil)
        #expect(setup.model.subagentCard(forTask: "Compare two CSV parsing") == nil)
    }
}
