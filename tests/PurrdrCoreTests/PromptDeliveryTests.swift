import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 送出 prompt(行為規格 F6.5、§3.6、§7.3、R-P01–R-P05、R-P13–R-P15)。全部走假主機，不碰任何真實 agent。
///
/// 回應來源見 `PromptReplies`(`agent.prompt` 不錄，以唯讀錄製的 `agent.wait` 回應為底改動)。
@Suite("送出 prompt")
struct PromptDeliveryTests {
    static let bridge = HerdrCommand.bridge()
    static let paneID = "w1:p6"
    static let claude = Agent(paneID: paneID, workspaceID: "w1", kind: "claude", status: .idle)

    static func prompted(delivery: String? = nil) -> FakeReply { PromptReplies.prompted(delivery: delivery) }
    static func error(_ code: String, _ message: String) -> FakeReply { PromptReplies.error(code, message) }
    static let keysAccepted = PromptReplies.keysAccepted
    static let silent = PromptReplies.silent

    static func snapshot(status: String) -> FakeReply {
        .recorded("session.snapshot.ndjson") { SnapshotEdit.agent(paneID, in: &$0) { $0["agent_status"] = status } }
    }

    static func delivery(_ host: FakeHost, sleeper: RecordingSleeper = RecordingSleeper()) -> PromptDelivery {
        PromptDelivery(client: HerdrClient(channel: host, sleep: sleeper.sleep), sleep: sleeper.sleep)
    }

    // MARK: - prompt 路徑

    @Test("已送達:agent.prompt 帶 wait until [working, blocked]、8 秒;我方期限 8+20 秒;bridge 不送 EOF")
    func deliveredWaitsForWorkingOrBlocked() async throws {
        let host = FakeHost()
        let sleeper = RecordingSleeper()
        await host.expect(Self.bridge, reply: Self.prompted())

        let outcome = await Self.delivery(host, sleeper: sleeper).send("整理一下\n第二行", to: Self.claude)

        #expect(outcome == .delivered)
        let executions = await host.executions
        #expect(executions.map(\.stdinText) == [
            #"{"id":"purrdr:agent.prompt","method":"agent.prompt","params":{"target":"w1:p6","text":"整理一下\n第二行","wait":{"timeout_ms":8000,"until":["working","blocked"]}}}"# + "\n",
        ])
        #expect(executions.first?.closedStdin == false)
        // 我方逾時必須長於 herdr 的等待，否則會放棄一個即將回答的等待(§3.6)。
        #expect(await sleeper.requested == [.seconds(28)])
    }

    @Test("沒有反應:herdr 自己的 timeout 與 agent_prompt_stalled 都是停滯，不補 Enter、不重送")
    func herdrTimeoutAndStallAreNoResponse() async throws {
        for reply in [
            FakeReply.recorded("error.agent-wait-timeout.ndjson"),
            Self.error("agent_prompt_stalled", "agent prompt produced no observed working or blocked state within 5000ms"),
        ] {
            let host = FakeHost()
            await host.expect(Self.bridge, reply: reply)

            let outcome = await Self.delivery(host).send("hi", to: Self.claude)

            #expect(outcome == .noResponse)
            #expect(await host.executions.count == 1)
        }
    }

    @Test("agent 在等回答(agent_blocked／agent_input_pending):什麼都沒送出，要先回答")
    func blockedAgentNeedsAnswer() async throws {
        for code in ["agent_blocked", "agent_input_pending"] {
            let host = FakeHost()
            await host.expect(Self.bridge, reply: Self.error(code, "agent is waiting for input"))

            let outcome = await Self.delivery(host).send("hi", to: Self.claude)

            #expect(outcome == .needsAnswer)
        }
    }

    @Test("其他 herdr 錯誤：主機拒絕，保留 herdr 原文")
    func otherHerdrErrorKeepsMessage() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.error("agent_not_found", "agent not found: w1:p6"))

        let outcome = await Self.delivery(host).send("hi", to: Self.claude)

        #expect(outcome == .rejected(message: "agent not found: w1:p6"))
    }

    /// R-P05、§7.3:連線層逾時 = 不知道有沒有送到。重送會送兩次(#83)。
    @Test("連線層逾時：期限到就放棄並回報無法確認(連線斷了),不重送、不補 Enter")
    func transportTimeoutIsNeverResent() async throws {
        let host = FakeHost()
        let sleeper = RecordingSleeper { $0 == .seconds(28) }
        await host.expect(Self.bridge, reply: Self.silent)
        // 若有重送或補 Enter,這些預期會被吃掉。
        await host.expect(Self.bridge, reply: Self.prompted())
        await host.expect(Self.bridge, reply: Self.snapshot(status: "idle"))

        let outcome = await Self.delivery(host, sleeper: sleeper).send("hi", to: Self.claude)

        #expect(outcome == .unconfirmed(.connectionLost))
        let executions = await host.executions
        #expect(executions.count == 1)
        #expect(executions.first?.closed == true)
    }

    @Test("連線中斷(bridge 沒回任何東西就結束):無法確認，不重送")
    func droppedConnectionIsNeverResent() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        await host.expect(Self.bridge, reply: Self.prompted())

        let outcome = await Self.delivery(host).send("hi", to: Self.claude)

        #expect(outcome == .unconfirmed(.connectionLost))
        #expect(await host.executions.count == 1)
    }

    // MARK: - 無法驗證(fork 才有)→ fallback Enter

    @Test("無法驗證且 agent 原本閒置：等 3.5 秒沒變化，新鮮讀到 idle 才補一個 Enter,之後變 working 視為送達")
    func unverifiedIdleGetsOneFallbackEnter() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.prompted(delivery: "written_to_pty"))
        await host.expect(Self.bridge, reply: .recorded("error.agent-wait-timeout.ndjson"))
        await host.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await host.expect(Self.bridge, reply: Self.keysAccepted)
        await host.expect(Self.bridge, reply: .recorded("agent.wait.matched.ndjson"))

        let outcome = await Self.delivery(host).send("hi", to: Self.claude)

        #expect(outcome == .delivered)
        let requests = await host.executions.map(\.stdinText)
        #expect(requests.count == 5)
        #expect(requests[1] == #"{"id":"purrdr:agent.wait","method":"agent.wait","params":{"target":"w1:p6","timeout_ms":3500,"until":["working","blocked"]}}"# + "\n")
        #expect(requests[2].contains(#""method":"session.snapshot""#))
        #expect(requests[3] == #"{"id":"purrdr:pane.send_keys","method":"pane.send_keys","params":{"keys":["enter"],"pane_id":"w1:p6"}}"# + "\n")
        #expect(requests[4].contains(#""timeout_ms":2500"#))
    }

    /// R-P03:補 Enter 進 blocked 的權限選單曾批准一個沒人看過的工具呼叫(#76)。
    @Test("無法驗證但新鮮讀到 blocked:絕不補 Enter,回報可能卡在終端機")
    func unverifiedNeverSendsEnterIntoBlocked() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.prompted(delivery: "written_to_pty"))
        await host.expect(Self.bridge, reply: .recorded("error.agent-wait-timeout.ndjson"))
        await host.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await host.expect(Self.bridge, reply: Self.keysAccepted)
        await host.expect(Self.bridge, reply: .recorded("agent.wait.matched.ndjson"))

        let outcome = await Self.delivery(host).send("hi", to: Self.claude)

        #expect(outcome == .unconfirmed(.mayBeInTerminal))
        let requests = await host.executions.map(\.stdinText)
        #expect(requests.count == 3)
        #expect(!requests.contains { $0.contains("send_keys") })
    }

    @Test("無法驗證且讀不到新鮮狀態：不補 Enter")
    func unverifiedWithoutFreshStatusSendsNoEnter() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.prompted(delivery: "written_to_pty"))
        await host.expect(Self.bridge, reply: .recorded("error.agent-wait-timeout.ndjson"))
        await host.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        await host.expect(Self.bridge, reply: Self.keysAccepted)

        let outcome = await Self.delivery(host).send("hi", to: Self.claude)

        #expect(outcome == .unconfirmed(.mayBeInTerminal))
        #expect(await host.executions.count == 3)
    }

    @Test("無法驗證但 agent 原本就在工作:prompt 只會排隊，不等、不補 Enter")
    func unverifiedWhileWorkingIsQueued() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.prompted(delivery: "written_to_pty"))
        var working = Self.claude
        working.status = .working

        let outcome = await Self.delivery(host).send("hi", to: working)

        #expect(outcome == .delivered)
        #expect(await host.executions.count == 1)
    }

    // MARK: - Codex

    @Test("Codex 沒有確定送達：只等對話紀錄回執，永不重送、不補 Enter")
    func codexIsNeverResent() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.error("agent_prompt_stalled", "agent prompt produced no observed working or blocked state within 5000ms"))
        await host.expect(Self.bridge, reply: Self.prompted())
        let codex = Agent(paneID: Self.paneID, workspaceID: "w1", kind: "codex", status: .idle)

        let outcome = await Self.delivery(host).send("hi", to: codex)

        #expect(outcome == .unconfirmed(.codexNoReceipt))
        #expect(await host.executions.count == 1)
    }

    // MARK: - Slash 指令

    /// R-P15:`/model` 這類本地指令永遠不會讓 agent 工作，等待必逾時;補的 Enter 會選到面板的某一列。
    @Test("Slash 指令：不帶 wait、期限 20 秒，送出就算數，絕不補 Enter")
    func slashCommandIsNotAwaited() async throws {
        let host = FakeHost()
        let sleeper = RecordingSleeper()
        await host.expect(Self.bridge, reply: Self.prompted(delivery: "written_to_pty"))

        let outcome = await Self.delivery(host, sleeper: sleeper).send("/model opus", to: Self.claude)

        #expect(outcome == .submittedCommand)
        #expect(await host.executions.map(\.stdinText) == [
            #"{"id":"purrdr:agent.prompt","method":"agent.prompt","params":{"target":"w1:p6","text":"/model opus"}}"# + "\n",
        ])
        #expect(await sleeper.requested == [.seconds(20)])
    }

    @Test("Slash 指令的判斷：斜線後是字母開頭的名稱，接空白或結尾;路徑與一般文字不算")
    func slashCommandDetection() {
        #expect(PromptDelivery.isSlashCommand("/model", kind: "claude"))
        #expect(PromptDelivery.isSlashCommand("/review this file", kind: "codex"))
        #expect(PromptDelivery.isSlashCommand("/compact\nkeep the plan", kind: "claude"))
        #expect(!PromptDelivery.isSlashCommand("/Users/demo/a.txt 看一下", kind: "claude"))
        #expect(!PromptDelivery.isSlashCommand("/1st", kind: "claude"))
        #expect(!PromptDelivery.isSlashCommand("look at /model", kind: "claude"))
        // 不認得 slash 指令的 agent 走一般 prompt 路徑。
        #expect(!PromptDelivery.isSlashCommand("/model", kind: "pi"))
    }

    // MARK: - Shell `!` 指令

    /// F6.4、#43:`!指令` 在 agent 的 shell 執行，Claude 不會開始工作，等 working 只會逾時;補的 Enter 也不該送。
    @Test("Claude 的 `!` 指令：照打的內容送出、不帶 wait、期限 20 秒，送出就算數，絕不補 Enter")
    func shellCommandIsNotAwaited() async throws {
        let host = FakeHost()
        let sleeper = RecordingSleeper()
        await host.expect(Self.bridge, reply: Self.prompted(delivery: "written_to_pty"))

        let outcome = await Self.delivery(host, sleeper: sleeper).send("!git status", to: Self.claude)

        #expect(outcome == .submittedCommand)
        #expect(await host.executions.map(\.stdinText) == [
            #"{"id":"purrdr:agent.prompt","method":"agent.prompt","params":{"target":"w1:p6","text":"!git status"}}"# + "\n",
        ])
        #expect(await sleeper.requested == [.seconds(20)])
    }

    @Test("Shell 指令的判斷：只有 Claude、且以 `!` 開頭")
    func shellCommandDetection() {
        #expect(PromptDelivery.isShellCommand("!ls -la", kind: "claude"))
        #expect(PromptDelivery.isShellCommand("! git status", kind: "claude"))
        #expect(!PromptDelivery.isShellCommand("run !ls", kind: "claude"))
        #expect(!PromptDelivery.isShellCommand("!ls", kind: "codex"))
    }

    // MARK: - 中斷

    static let escKeys = #"{"id":"purrdr:pane.send_keys","method":"pane.send_keys","params":{"keys":["esc"],"pane_id":"w1:p6"}}"# + "\n"
    static let controlCKeys = #"{"id":"purrdr:pane.send_keys","method":"pane.send_keys","params":{"keys":["ctrl+c"],"pane_id":"w1:p6"}}"# + "\n"

    static func keyRequests(_ host: FakeHost) async -> [String] {
        await host.executions.map(\.stdinText).filter { $0.contains("send_keys") }
    }

    /// R-P13:只送一個 Esc(第二個會開 Claude 的回溯選單);主機會收下不認得的鍵名，所以要確認離開 working。
    @Test("停止：先讀新鮮的狀態，在 working 才送一個 Esc,之後每 500ms 讀狀態，離開 working 就算停了")
    func stopSendsOneEscAndConfirms() async throws {
        let host = FakeHost()
        let sleeper = RecordingSleeper { $0 == .milliseconds(500) }
        await host.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await host.expect(Self.bridge, reply: Self.keysAccepted)
        await host.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await host.expect(Self.bridge, reply: Self.snapshot(status: "idle"))

        let outcome = await Self.delivery(host, sleeper: sleeper).stop(paneID: Self.paneID)

        #expect(outcome == .stopped)
        let requests = await host.executions.map(\.stdinText)
        #expect(requests.first?.contains(#""method":"session.snapshot""#) == true)
        #expect(await Self.keyRequests(host) == [Self.escKeys])
    }

    @Test("停止：3 秒內一直在 working → 還在工作(不再送第二個 Esc)")
    func stopReportsStillWorking() async throws {
        let host = FakeHost()
        let sleeper = RecordingSleeper { $0 == .milliseconds(500) }
        await host.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await host.expect(Self.bridge, reply: Self.keysAccepted)
        for _ in 0..<6 { await host.expect(Self.bridge, reply: Self.snapshot(status: "working")) }

        let outcome = await Self.delivery(host, sleeper: sleeper).stop(paneID: Self.paneID)

        #expect(outcome == .stillWorking)
        #expect(await Self.keyRequests(host).count == 1)
        #expect(await host.unmetExpectations.isEmpty)
    }

    /// #220:讀不到狀態不能當成功，否則按鈕回到送出、使用者以為停了。
    @Test("停止：送出 Esc 之後讀不到狀態 → 無法確認(不是已停止)")
    func stopReportsUnconfirmedWhenStatusUnreadable() async throws {
        let host = FakeHost()
        let sleeper = RecordingSleeper { $0 == .milliseconds(500) }
        await host.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await host.expect(Self.bridge, reply: Self.keysAccepted)
        await host.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))

        let outcome = await Self.delivery(host, sleeper: sleeper).stop(paneID: Self.paneID)

        #expect(outcome == .unconfirmed)
    }

    /// F6.7:停止**永不**送給「需要你」的 agent——中斷可能把問題關掉。畫面上的狀態可能是 2 秒前的，所以送前重讀。
    @Test("停止：送前重讀到「需要你」(blocked 或 input_pending)→ 一個按鍵都不送")
    func stopNeverInterruptsAgentThatNeedsYou() async throws {
        for change in [
            { (agent: inout [String: Any]) in agent["agent_status"] = "blocked" },
            { (agent: inout [String: Any]) in agent["agent_status"] = "idle"; agent["input_pending"] = true },
        ] {
            let host = FakeHost()
            await host.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") { SnapshotEdit.agent(Self.paneID, in: &$0, change) })
            // 主機會收下按鍵：實作若錯送了，會留在送出紀錄裡。
            await host.expect(Self.bridge, reply: Self.keysAccepted)

            // 等待立刻結束(herdr 請求的期限除外):實作若錯送了 Esc,測試不會卡在 500ms 的確認迴圈。
            let outcome = await Self.delivery(host, sleeper: RecordingSleeper { $0 < HostCommandDeadline.standard }).stop(paneID: Self.paneID)

            #expect(outcome == .needsAnswer)
            #expect(await Self.keyRequests(host).isEmpty)
        }
    }

    @Test("停止：送前重讀到已經不在 working → 不送 Esc(多一個 Esc 會開回溯選單);讀不到狀態 → 不送，回報失敗")
    func stopSendsNothingWhenNotWorkingOrUnknown() async throws {
        let idle = FakeHost()
        await idle.expect(Self.bridge, reply: Self.snapshot(status: "done"))
        #expect(await Self.delivery(idle).stop(paneID: Self.paneID) == .stopped)
        #expect(await Self.keyRequests(idle).isEmpty)

        let offline = FakeHost()
        await offline.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        #expect(await Self.delivery(offline).stop(paneID: Self.paneID) == .failed)
        #expect(await Self.keyRequests(offline).isEmpty)
    }

    @Test("強制結束：送前重讀在 working 才送 ctrl+c,不確認結果")
    func forceQuitSendsControlC() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: Self.snapshot(status: "working"))
        await host.expect(Self.bridge, reply: Self.keysAccepted)

        let outcome = await Self.delivery(host).forceQuit(paneID: Self.paneID)

        #expect(outcome == .sent)
        #expect(await Self.keyRequests(host) == [Self.controlCKeys])
    }

    @Test("強制結束：「需要你」的 agent 永不送 ctrl+c;不在 working 或讀不到狀態也不送")
    func forceQuitNeverInterruptsAgentThatNeedsYou() async throws {
        let blocked = FakeHost()
        await blocked.expect(Self.bridge, reply: Self.snapshot(status: "blocked"))
        await blocked.expect(Self.bridge, reply: Self.keysAccepted)
        #expect(await Self.delivery(blocked).forceQuit(paneID: Self.paneID) == .needsAnswer)
        #expect(await Self.keyRequests(blocked).isEmpty)

        let pending = FakeHost()
        await pending.expect(Self.bridge, reply: .recorded("session.snapshot.ndjson") {
            SnapshotEdit.agent(Self.paneID, in: &$0) { $0["agent_status"] = "idle"; $0["input_pending"] = true }
        })
        await pending.expect(Self.bridge, reply: Self.keysAccepted)
        #expect(await Self.delivery(pending).forceQuit(paneID: Self.paneID) == .needsAnswer)
        #expect(await Self.keyRequests(pending).isEmpty)

        let idle = FakeHost()
        await idle.expect(Self.bridge, reply: Self.snapshot(status: "idle"))
        await idle.expect(Self.bridge, reply: Self.keysAccepted)
        #expect(await Self.delivery(idle).forceQuit(paneID: Self.paneID) == .notWorking)
        #expect(await Self.keyRequests(idle).isEmpty)

        let offline = FakeHost()
        await offline.expect(Self.bridge, reply: FakeReply(exitCode: 255, trigger: .afterStdinLine))
        #expect(await Self.delivery(offline).forceQuit(paneID: Self.paneID) == .failed)
        #expect(await Self.keyRequests(offline).isEmpty)
    }
}
