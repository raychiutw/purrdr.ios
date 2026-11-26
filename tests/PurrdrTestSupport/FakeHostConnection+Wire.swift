import Foundation
import PurrdrCore

/// 把錄製的 herdr 回應行換成型別化 stub:`expect(.snapshot, wire: Fixtures.data("session.snapshot.ndjson"))`。
///
/// 回應行由 SSH 路線的解析層(`HerdrWireClient`)判讀成型別化的值或失敗(例如錯誤 envelope 變成 `HerdrError.herdr`)，
/// 之後上層只看到型別化操作;錄製檔本身(真實主機的回應)仍是各種情境的資料來源。
extension FakeHostConnection {
    public func expect(_ operation: Operation, wire reply: Data) async {
        let client = HerdrWireClient(wire: ReplayWire(reply: reply))
        do {
            switch operation {
            case .snapshot: stub(operation, try await client.snapshot())
            case .ping: stub(operation, try await client.ping())
            case .integrations: stub(operation, try await client.integrations())
            case .paneRead: stub(operation, try await client.readPane(paneID: "w1:p1", lines: 1, format: .text))
            case .sendKeys:
                try await client.sendKeys(paneID: "w1:p1", keys: [], expecting: .none)
                stub(operation)
            case .sendText:
                try await client.sendText(paneID: "w1:p1", text: "", expecting: .none)
                stub(operation)
            case .reportPresence:
                try await client.reportPresence(paneID: "w1:p1", model: nil, seq: 0)
                stub(operation)
            case .workspaceRename:
                try await client.renameWorkspace("w1", to: "")
                stub(operation)
            case .tabRename:
                try await client.renameTab("w1:t1", to: "")
                stub(operation)
            case .tabClose:
                try await client.closeTab("w1:t1")
                stub(operation)
            case .workspaceClose:
                try await client.closeWorkspace("w1")
                stub(operation)
            case .worktreeCreate: stub(operation, try await client.createWorktree(from: "w1", branch: "b"))
            case .workspaceCreate: stub(operation, try await client.createWorkspace(cwd: "/", label: nil))
            case .tabCreate: stub(operation, try await client.createTab(in: "w1", label: nil))
            case .agentStart:
                stub(operation, try await client.startAgent(
                    AgentStartRequest(name: "x", kind: "x", paneID: "w1:p1", arguments: [], timeout: .seconds(1))))
            case .agentLaunchState: stub(operation, try await client.agentLaunchState(target: "w1:p1"))
            case .sessionsList: stub(operation, try await client.listSessions(cwd: "/", agent: "claude"))
            case .agentPrompt: stub(operation, try await client.prompt(target: "w1:p1", text: "", wait: nil, expecting: .none))
            case .agentWait: stub(operation, try await client.waitForAgent(target: "w1:p1", until: [], timeout: .seconds(1)))
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
                guard let event = try HerdrWireClient.decodeEventStream(Data(line), started: started) else { continue }
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

/// 只回一行固定回應的 herdr wire(把錄製的回應交給 `HerdrWireClient` 判讀用)。
private struct ReplayWire: HerdrWire {
    let reply: Data

    func herdrRequest(_ request: Data, deadline: Duration) async throws -> Data {
        reply.firstIndex(of: 0x0A).map { reply[reply.startIndex..<$0] } ?? reply
    }

    func herdrEvents(_ request: Data) async throws -> AsyncThrowingStream<Data, any Error> {
        throw FakeHostConnectionError.unsupported
    }

    func readTranscript(_ request: TranscriptRequest) async throws -> Data {
        throw FakeHostConnectionError.unsupported
    }

    func checksSendExpectations() async -> Bool { false }
}
