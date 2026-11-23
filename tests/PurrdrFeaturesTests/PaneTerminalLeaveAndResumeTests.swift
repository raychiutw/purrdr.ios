import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Pane 終端機只在畫面顯示時持有 Pane 的尺寸(#357,Heeler 做法):
/// 顯示時 Pane 改成手機的欄列數,離開(返回、切 tab、進背景、鎖定)立刻放開控制讓電腦的版面還原,回到畫面重新套用。
@MainActor
@Suite("Pane 終端機:離開還原、回來重新套用")
struct PaneTerminalLeaveAndResumeTests {
    typealias Base = PaneTerminalModelTests

    @Test("回到畫面:離開時放開控制,回來以同一組手機格數重新接上(不帶 --takeover)")
    func resumeReappliesPhoneSize() async {
        let host = FakeHost()
        await host.expect(Base.control(columns: 40, rows: 12), reply: FakeReply(keepsOpen: true))
        await host.expect(Base.control(columns: 40, rows: 12), reply: FakeReply(keepsOpen: true))
        let model = Base.makeModel(host)
        model.viewDidResize(columns: 40, rows: 12)
        _ = await host.waitForExecutions(1, timeout: Base.timeout)

        model.hangUp()
        #expect(await host.waitForStdin(ofExecution: 0, timeout: Base.timeout) { $0.stdinText.contains("terminal.release") })
        #expect(model.status == .disconnected)

        model.resume()
        #expect(await host.waitForExecutions(2, timeout: Base.timeout) == 2)
        #expect(await host.unmetExpectations.isEmpty)
        #expect(model.status == .connecting)
    }

    @Test("不是自己放開的就不自動接回:連線中斷要使用者按「重新連線」")
    func resumeDoesNotRevive() async {
        let host = FakeHost()
        await host.expect(Base.control(), reply: FakeReply(keepsOpen: true))
        // 若 resume 誤把中斷的連線接回，會吃掉這個預期。
        await host.expect(Base.control(), reply: FakeReply(keepsOpen: true))
        let model = Base.makeModel(host)
        model.viewDidResize(columns: 40, rows: 12)
        _ = await host.waitForExecutions(1, timeout: Base.timeout)
        await Base.replay("12-sigkill-then-reattach.stdout.ndjson", on: host)
        await Base.eventually { model.status == .disconnected }

        model.resume()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.status == .disconnected)
        #expect(await host.executions.count == 1)
        #expect(await host.unmetExpectations.count == 1)
    }

    @Test("第一次顯示:還沒有格數時 resume 什麼都不做")
    func resumeBeforeFirstSizeDoesNothing() async {
        let host = FakeHost()
        let model = Base.makeModel(host)

        model.resume()
        try? await Task.sleep(for: .milliseconds(30))

        #expect(model.status == .waitingForSize)
        #expect(await host.executions.isEmpty)
    }

    @Test("回來時電腦正在操作(別的 client 接著 Pane) → 顯示被佔用，提供「接管」,不自動搶")
    func resumeFindsPaneInUse() async {
        let host = FakeHost()
        await host.expect(Base.control(), reply: FakeReply(keepsOpen: true))
        await host.expect(Base.control(), reply: FakeReply(keepsOpen: true))
        let model = Base.makeModel(host)
        model.viewDidResize(columns: 40, rows: 12)
        _ = await host.waitForExecutions(1, timeout: Base.timeout)
        model.hangUp()

        model.resume()
        #expect(await host.waitForExecutions(2, timeout: Base.timeout) == 2)
        await Base.replay("06-takeover-B.stdout.ndjson", on: host, execution: 1)
        await Base.eventually { model.status == .inUse }

        #expect(model.status == .inUse)
        #expect(model.canTakeOver)
        #expect(model.bannerText == "The host is using this pane. Take over to use it here.")
        #expect(await host.executions.map(\.command) == [Base.control(), Base.control()])
    }

    @Test("連線中斷的橫幅:說明並提供「重新連線」")
    func disconnectedBanner() async {
        let host = FakeHost()
        let model = await Base.connected(host)
        await Base.replay("12-sigkill-then-reattach.stdout.ndjson", on: host)
        await Base.eventually { model.status == .disconnected }

        #expect(model.statusText == "Connection Lost")
        #expect(model.bannerText == "The connection dropped. Reconnect to pick up where this pane is now.")
        #expect(model.canReconnect)
    }

    @Test("快速進出:接上前就離開也送 release,不留控制;立刻回來只留一條新連線")
    func quickLeaveAndReturnLeavesNothingBehind() async {
        let host = FakeHost()
        await host.expect(Base.control(), reply: FakeReply(keepsOpen: true))
        await host.expect(Base.control(), reply: FakeReply(keepsOpen: true))
        let model = Base.makeModel(host)
        model.viewDidResize(columns: 40, rows: 12)
        // 還沒收到任何 frame(連線中)就離開,再立刻回來。
        model.hangUp()
        model.resume()
        #expect(await host.waitForExecutions(2, timeout: Base.timeout) == 2)

        // 兩條連線誰先開不一定:一條放開控制並關閉 stdin(留下 release),另一條仍然開著、沒有任何 release。
        #expect(await host.waitForStdin(ofExecution: 0, timeout: Base.timeout) { _ in true })
        await Base.eventually {
            let first = await Self.releaseCount(host, execution: 0)
            let second = await Self.releaseCount(host, execution: 1)
            return first + second == 1
        }
        var released: [Int] = []
        var open: [Int] = []
        for execution in 0..<2 {
            let lines = await Base.sentLines(host, execution: execution)
            if lines.contains(where: { $0["type"] as? String == "terminal.release" }) { released.append(execution) } else { open.append(execution) }
        }
        #expect(released.count == 1 && open.count == 1)
        if let released = released.first, let open = open.first {
            #expect(await host.waitForStdin(ofExecution: released, timeout: Base.timeout) { $0.closedStdin })
            #expect(await Base.sentLines(host, execution: open).isEmpty)
            #expect(await host.executions[open].closedStdin == false)
        }
        #expect(model.status == .connecting)
    }

    static func releaseCount(_ host: FakeHost, execution: Int) async -> Int {
        await Base.sentLines(host, execution: execution).filter { $0["type"] as? String == "terminal.release" }.count
    }

    @Test("放開完成可以等:進背景時 App 要等 release 送出才能被系統凍結")
    func releasedCompletesAfterReleaseIsSent() async {
        let host = FakeHost()
        let model = await Base.connected(host)

        model.hangUp()
        await model.released()

        #expect(await Base.sentLines(host).last == ["type": "terminal.release"])
        #expect(await host.executions[0].closedStdin)
    }

    @Test("唯讀裝置離開再回來也不送 resize(本來就不改尺寸)")
    func readOnlyNeverResizes() async {
        let connection = FakeHostConnection()
        await connection.expectPaneTerminal(replaying: "01-handshake-echo-release.stdout.ndjson", readOnly: true)
        await connection.expectPaneTerminal(replaying: "01-handshake-echo-release.stdout.ndjson", readOnly: true)
        let model = PaneTerminalModel(client: PaneTerminalClient(connection: connection), paneID: "w1:p1", title: "t",
                                      resizeDebounce: .zero, sleep: { _ in })
        model.viewDidResize(columns: 40, rows: 12)
        await Base.eventually { model.status == .connected }
        model.hangUp()
        model.resume()
        model.viewDidResize(columns: 60, rows: 15)
        await Base.eventually { model.status == .connected }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await connection.paneTerminalInputs.isEmpty)
    }
}
