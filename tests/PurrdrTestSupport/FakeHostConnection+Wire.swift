import Foundation
import PurrdrCore

/// 把錄製的 herdr 回應行換成型別化 stub:`expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))`。
///
/// 回應行由 SSH 路線的解析層(`HerdrClient`)判讀成型別化的值或失敗(例如錯誤 envelope 變成 `HerdrError.herdr`)，
/// 之後上層只看到型別化操作;錄製檔本身(真實主機的回應)仍是各種情境的資料來源。
extension FakeHostConnection {
    public func expect(_ operation: Operation, wire reply: Data) async {
        let probe = FakeHostConnection()
        await probe.expect(operation.rawValue, reply: reply)
        let client = HerdrClient(connection: probe)
        do {
            switch operation {
            case .snapshot: stub(operation, try await client.wireSnapshot())
            case .ping: stub(operation, try await client.wirePing())
            case .integrations: stub(operation, try await client.wireIntegrations())
            case .paneRead: stub(operation, try await client.wireReadPane(paneID: "w1:p1", lines: 1, format: .text))
            case .sendKeys:
                try await client.wireSendKeys(paneID: "w1:p1", keys: [], expecting: .none)
                stub(operation)
            case .sendText:
                try await client.wireSendText(paneID: "w1:p1", text: "", expecting: .none)
                stub(operation)
            case .reportPresence:
                try await client.wireReportPresence(paneID: "w1:p1", model: nil, seq: 0)
                stub(operation)
            case .workspaceRename:
                try await client.wireRenameWorkspace("w1", to: "")
                stub(operation)
            case .tabRename:
                try await client.wireRenameTab("w1:t1", to: "")
                stub(operation)
            case .tabClose:
                try await client.wireCloseTab("w1:t1")
                stub(operation)
            case .workspaceClose:
                try await client.wireCloseWorkspace("w1")
                stub(operation)
            case .worktreeCreate: stub(operation, try await client.wireCreateWorktree(from: "w1", branch: "b"))
            case .workspaceCreate: stub(operation, try await client.wireCreateWorkspace(cwd: "/", label: nil))
            case .tabCreate: stub(operation, try await client.wireCreateTab(in: "w1", label: nil))
            case .agentStart:
                stub(operation, try await client.wireStartAgent(
                    AgentStartRequest(name: "x", kind: "x", paneID: "w1:p1", arguments: [], timeout: .seconds(1))))
            case .agentLaunchState: stub(operation, try await client.wireAgentLaunchState(target: "w1:p1"))
            case .sessionsList: stub(operation, try await client.wireListSessions(cwd: "/", agent: "claude"))
            case .agentPrompt: stub(operation, try await client.wirePrompt(target: "w1:p1", text: "", wait: nil, expecting: .none))
            case .agentWait: stub(operation, try await client.wireWaitForAgent(target: "w1:p1", until: [], timeout: .seconds(1)))
            case .transcriptLocate, .transcriptWindow, .transcriptTail, .transcriptPreviews, .subagentLocate, .workflow, .delegation:
                preconditionFailure("對話紀錄的 stub 直接給型別化的值")
            }
        } catch {
            stub(operation, failure: error)
        }
    }

    /// 事件訂閱的預期:`reply` 是錄製的回應行(ack,可再接事件行)。錯誤 envelope 讓訂閱的串流在它之前的事件送完後以錯誤結束。
    public func expectSubscription(wire reply: Data) {
        var events: [HerdrEvent] = []
        var started = false
        var failure: (any Error)?
        for line in reply.split(separator: 0x0A) {
            do {
                guard let event = try HerdrClient.decodeEventStream(Data(line), started: started) else { continue }
                if event == .subscriptionStarted { started = true }
                events.append(event)
            } catch {
                failure = error
                break
            }
        }
        expectSubscription(events: events, endingWith: failure)
    }
}
