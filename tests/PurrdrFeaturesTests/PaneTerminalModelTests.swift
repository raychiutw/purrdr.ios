import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import SwiftTerm
import Testing

/// Pane 終端機畫面的 model:經假主機回放 #4 spike 錄下的 `terminal session control` 串流。
@MainActor
@Suite("Pane 終端機")
struct PaneTerminalModelTests {
    static func control(columns: Int = 40, rows: Int = 12, takeover: Bool = false) -> String {
        HerdrCommand.terminalSessionControl(target: "w1:p1", columns: columns, rows: rows, takeover: takeover)
    }

    /// 去抖的等待注入假的(預設一直等到被取消)，測試不依賴真實時間。
    static func makeModel(
        _ host: FakeHost, debounce: Duration = .milliseconds(30),
        sleep: @escaping @Sendable (Duration) async throws -> Void = RecordingSleeper().sleep
    ) -> PaneTerminalModel {
        PaneTerminalModel(client: PaneTerminalClient(channel: host), paneID: "w1:p1", title: "Tidy up the CSV export",
                          resizeDebounce: debounce, sleep: sleep)
    }

    /// 把錄製檔的 stdout 送進假主機。`finish: false` 時只送 frame(連線保持開著)。
    static func replay(_ fixture: String, on host: FakeHost, execution: Int = 0, finish: Bool = true) async {
        for line in Fixtures.sessionControlLines(fixture) {
            if !finish, String(decoding: line, as: UTF8.self).contains(#""type":"terminal.closed""#) { continue }
            await host.send(.stdout(line + [0x0A]), toExecution: execution)
        }
        if finish { await host.finish(execution: execution) }
    }

    /// 非同步對齊的等待上限。條件一成立就往下走，所以只影響失敗時多久才報;
    /// 給得寬，機器很忙(平行跑測試)時才不會在條件成立前就逾時。
    static let timeout: Duration = .seconds(30)

    /// 等非同步工作把狀態推到位。逾時就讓後面的 `#expect` 失敗。
    static func eventually(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 以 SwiftTerm 的 headless 模擬器當畫面，驗證 frame 真的畫得出來。
    final class Screen: TerminalDelegate {
        lazy var terminal: Terminal = {
            var options = TerminalOptions.default
            options.cols = 40
            options.rows = 12
            return Terminal(delegate: self, options: options)
        }()

        func send(source: Terminal, data: ArraySlice<UInt8>) {}

        func feed(_ data: Data) { terminal.feed(byteArray: Array(data)) }

        var lines: [String] {
            (0..<terminal.rows).map {
                // herdr 會把整列補滿空白，所以去掉行尾空白再比。
                (terminal.getLine(row: $0)?.translateToString(
                    skipNullCellsFollowingWide: true, characterProvider: terminal.getCharacter(for:)
                ) ?? "").replacingOccurrences(of: " +$", with: "", options: .regularExpression)
            }
        }
    }

    static func sentLines(_ host: FakeHost, execution: Int = 0) async -> [NSDictionary] {
        guard await host.executions.count > execution else { return [] }
        return await host.executions[execution].stdinText.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? NSDictionary
        }
    }

    static func sentResizes(_ host: FakeHost) async -> [[Int?]] {
        await sentLines(host).filter { $0["type"] as? String == "terminal.resize" }.map { [$0["cols"] as? Int, $0["rows"] as? Int] }
    }

    static func sentInput(_ host: FakeHost, execution: Int = 0) async -> [UInt8] {
        await sentLines(host, execution: execution).compactMap { line -> [UInt8]? in
            guard line["type"] as? String == "terminal.input" else { return nil }
            return (line["bytes"] as? String).flatMap { Data(base64Encoded: $0) }.map(Array.init)
        }.flatMap { $0 }
    }

    /// 開好一條連線並收到第一個 frame。
    static func connected(
        _ host: FakeHost, debounce: Duration = .milliseconds(30),
        sleep: @escaping @Sendable (Duration) async throws -> Void = RecordingSleeper().sleep
    ) async -> PaneTerminalModel {
        await host.expect(control(), reply: FakeReply(keepsOpen: true))
        let model = makeModel(host, debounce: debounce, sleep: sleep)
        model.viewDidResize(columns: 40, rows: 12)
        _ = await host.waitForExecutions(1, timeout: Self.timeout)
        await host.send(.stdout(Fixtures.sessionControlLines("01-handshake-echo-release.stdout.ndjson")[0] + [0x0A]), toExecution: 0)
        await eventually { model.status == .connected }
        return model
    }

    // MARK: - 連線與畫面

    @Test("畫面回報格數前不開連線;回報後以該格數開 control(不帶 --takeover),錄製的 frame 畫進模擬器")
    func connectsAfterSizeAndRendersFrames() async {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(keepsOpen: true))
        let model = Self.makeModel(host)
        let screen = Screen()
        model.attach { screen.feed($0) }
        #expect(model.status == .waitingForSize)
        #expect(await host.executions.isEmpty)

        model.viewDidResize(columns: 40, rows: 12)
        #expect(model.status == .connecting)
        #expect(model.statusText == "Connecting…")
        #expect(await host.waitForExecutions(1, timeout: Self.timeout) == 1)
        await Self.replay("01-handshake-echo-release.stdout.ndjson", on: host, finish: false)
        await Self.eventually { screen.lines.contains("hello-world") }

        #expect(model.status == .connected)
        #expect(model.statusText == "Connected")
        #expect(screen.lines[0] == #"$ echo hello-""world"#)
        #expect(screen.lines[1] == "hello-world")
    }

    @Test("中文、emoji 寬字元與組合字元畫在正確的格子")
    func rendersWideCharacters() async {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(keepsOpen: true))
        let model = Self.makeModel(host)
        let screen = Screen()
        model.attach { screen.feed($0) }

        model.viewDidResize(columns: 40, rows: 12)
        _ = await host.waitForExecutions(1, timeout: Self.timeout)
        await Self.replay("07-unicode-colors.stdout.ndjson", on: host, finish: false)
        await Self.eventually { screen.lines[8] == "中文輸入" }

        // 寬字元各佔兩格、組合字元與基底同一格，後面的字沒有被擠歪。
        #expect(screen.lines[6] == "中文 🐱 é x")
        #expect(screen.lines[8] == "中文輸入")
        #expect(screen.lines[9] == "$ echo pasted")
    }

    @Test("模擬器還沒接上前到達的 frame 先暫存，接上時依序補畫")
    func buffersFramesUntilAttached() async {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(keepsOpen: true))
        let model = Self.makeModel(host)
        model.viewDidResize(columns: 40, rows: 12)
        _ = await host.waitForExecutions(1, timeout: Self.timeout)
        // 整段回放(含結尾的 terminal.closed):事件依序處理，狀態變成中斷時，之前的 frame 一定都已暫存。
        await Self.replay("01-handshake-echo-release.stdout.ndjson", on: host)
        await Self.eventually { model.status == .disconnected }
        #expect(model.status == .disconnected)

        let screen = Screen()
        model.attach { screen.feed($0) }

        #expect(screen.lines[1] == "hello-world")
    }

    // MARK: - 結束、被拒、接管、重新連線

    @Test("已有別的 client 在操作 → 顯示被佔用並提供「接管」;接管以 --takeover 重開")
    func rejectedOffersTakeover() async {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(keepsOpen: true))
        await host.expect(Self.control(takeover: true), reply: FakeReply(keepsOpen: true))
        let model = Self.makeModel(host)
        model.viewDidResize(columns: 40, rows: 12)
        _ = await host.waitForExecutions(1, timeout: Self.timeout)

        await Self.replay("06-takeover-B.stdout.ndjson", on: host)
        await Self.eventually { model.status == .inUse }

        #expect(model.status == .inUse)
        #expect(model.canTakeOver)
        #expect(!model.canReconnect)

        model.takeOver()
        #expect(await host.waitForExecutions(2, timeout: Self.timeout) == 2)
        #expect(await host.executions.map(\.command) == [Self.control(), Self.control(takeover: true)])
        #expect(model.status == .connecting)
    }

    @Test("被別人接管 → 可以再接管回來")
    func takenOverOffersTakeover() async {
        let host = FakeHost()
        let model = await Self.connected(host)

        await host.send(.stdout(Data(#"{"reason":"terminal attach taken over","type":"terminal.closed"}"#.utf8) + [0x0A]), toExecution: 0)
        await Self.eventually { model.status == .takenOver }

        #expect(model.status == .takenOver)
        #expect(model.canTakeOver)
    }

    @Test("沒有 terminal.closed 就 EOF → 連線中斷，可重新連線;重新連線不帶 --takeover、沿用目前格數")
    func disconnectOffersReconnect() async {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(keepsOpen: true))
        await host.expect(Self.control(), reply: FakeReply(keepsOpen: true))
        let model = Self.makeModel(host)
        model.viewDidResize(columns: 40, rows: 12)
        _ = await host.waitForExecutions(1, timeout: Self.timeout)

        await Self.replay("12-sigkill-then-reattach.stdout.ndjson", on: host)
        await Self.eventually { model.status == .disconnected }

        #expect(model.status == .disconnected)
        #expect(model.statusText == "Connection Lost")
        #expect(model.canReconnect)
        #expect(!model.canTakeOver)

        model.reconnect()
        #expect(await host.waitForExecutions(2, timeout: Self.timeout) == 2)
        #expect(await host.executions.last?.command == Self.control())
    }

    @Test("Pane 裡的程式結束 → 已結束，不提供重新連線")
    func exitedEnds() async {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(keepsOpen: true))
        let model = Self.makeModel(host)
        model.viewDidResize(columns: 40, rows: 12)
        _ = await host.waitForExecutions(1, timeout: Self.timeout)

        await Self.replay("14-exited-control.stdout.ndjson", on: host)
        await Self.eventually { model.status == .ended }

        #expect(model.statusText == "Ended")
        #expect(!model.canReconnect)
        #expect(!model.canTakeOver)
    }

    @Test("找不到 Pane 或 herdr 沒跑起來 → 說明原因，不提供重新連線(永遠不會成功)")
    func notFoundIsUnavailable() async {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(keepsOpen: true))
        let model = Self.makeModel(host)
        model.viewDidResize(columns: 40, rows: 12)
        _ = await host.waitForExecutions(1, timeout: Self.timeout)

        await Self.replay("13-not-found-control.stdout.ndjson", on: host)
        await Self.eventually { if case .unavailable = model.status { true } else { false } }

        #expect(model.status == .unavailable("This pane no longer exists on the host."))
        #expect(!model.canReconnect)
    }

    @Test("掛斷(離開畫面、進背景)送 release 並關閉 stdin;之後可重新連線，不自動重連")
    func hangUpReleases() async {
        let host = FakeHost()
        let model = await Self.connected(host)

        model.hangUp()
        #expect(await host.waitForStdin(ofExecution: 0, timeout: Self.timeout) { $0.closedStdin })

        #expect(await Self.sentLines(host).last == ["type": "terminal.release"])
        #expect(model.status == .disconnected)
        // 連線整個收掉後(通道關閉)仍然只有一次執行。
        #expect(await host.waitForStdin(ofExecution: 0, timeout: Self.timeout) { $0.closed })
        #expect(await host.executions.count == 1)
    }

    // MARK: - 尺寸

    @Test("尺寸改變去抖後只送最後一次;0 格不送")
    func resizeIsDebounced() async {
        let host = FakeHost()
        let gate = SleepGate()
        let model = await Self.connected(host, debounce: .milliseconds(120), sleep: gate.sleep)

        // 像鍵盤滑出的動畫：去抖時間到之前就來了新尺寸。
        model.viewDidResize(columns: 50, rows: 14)
        model.viewDidResize(columns: 0, rows: 14)
        model.viewDidResize(columns: 60, rows: 15)
        model.viewDidResize(columns: 70, rows: 16)
        await Self.eventually { await gate.requested.count == 3 }
        // 去抖時間到：還在等的(沒被取消的)全部醒來。
        await gate.open()
        #expect(await host.waitForStdin(ofExecution: 0, timeout: Self.timeout) { $0.stdinText.contains("terminal.resize") })

        #expect(await Self.sentResizes(host) == [[70, 16]])
        #expect(await gate.requested == [.milliseconds(120), .milliseconds(120), .milliseconds(120)])
        // 前兩次的去抖被新尺寸取消，只有最後一次等滿。
        #expect(await gate.completed == 1)
    }

    @Test("格數限制在合理範圍(herdr 會接受 5000 欄並回很大的 frame)")
    func resizeIsClamped() async {
        let host = FakeHost()
        let model = await Self.connected(host, sleep: RecordingSleeper { _ in true }.sleep)

        model.viewDidResize(columns: 5000, rows: 900)
        #expect(await host.waitForStdin(ofExecution: 0, timeout: Self.timeout) { $0.stdinText.contains("terminal.resize") })

        #expect(await Self.sentResizes(host) == [[500, 200]])
    }

    // MARK: - 按鍵列與輸入

    @Test("鍵盤輸入照原樣送往遠端(含 Ctrl 組合鍵與 Esc)")
    func typedInputGoesToHost() async {
        let host = FakeHost()
        let model = await Self.connected(host)

        model.type(Data("ls\r".utf8))
        model.type(Data([0x03]))
        model.press(.escape)
        _ = await host.waitForStdin(ofExecution: 0, timeout: Self.timeout) { $0.stdinText.split(separator: "\n").count >= 3 }

        #expect(await Self.sentInput(host) == Array("ls\r".utf8) + [0x03, 0x1B])
    }

    @Test("Ctrl 黏著：鎖定後下一顆鍵(按鍵列或軟體鍵盤)帶 Ctrl,送出後放開")
    func stickyControl() async {
        let host = FakeHost()
        let model = await Self.connected(host)

        model.toggle(.control)
        #expect(model.modifiers == .control)
        model.type(Data("c".utf8))
        #expect(model.modifiers.isEmpty)
        model.toggle(.control)
        model.press(.up)
        #expect(model.modifiers.isEmpty)
        model.press(.character("/"))
        _ = await host.waitForStdin(ofExecution: 0, timeout: Self.timeout) { $0.stdinText.split(separator: "\n").count >= 3 }

        #expect(await Self.sentInput(host) == [0x03] + Array("\u{1B}[1;5A".utf8) + [0x2F])
    }

    @Test("貼上一律包 bracketed paste 標記，一則送出")
    func pasteIsBracketed() async {
        let host = FakeHost()
        let model = await Self.connected(host)

        model.paste("echo pasted")
        _ = await host.waitForStdin(ofExecution: 0, timeout: Self.timeout) { !$0.stdin.isEmpty }

        #expect(await Self.sentInput(host) == Array("\u{1B}[200~echo pasted\u{1B}[201~".utf8))
        #expect(await Self.sentLines(host).count == 1)
    }

    @Test("太大的貼上不送(切塊會破壞 bracketed paste),並提示")
    func oversizedPasteIsRejected() async {
        let host = FakeHost()
        let model = await Self.connected(host)

        model.paste(String(repeating: "x", count: 300 * 1024))
        // 輸入依序送出：之後的一顆鍵送到了，前面的貼上若有送一定排在它前面。
        model.press(.escape)
        _ = await host.waitForStdin(ofExecution: 0, timeout: Self.timeout) { !$0.stdin.isEmpty }

        #expect(await Self.sentLines(host).count == 1)
        #expect(await Self.sentInput(host) == [0x1B])
        #expect(model.notice == "This paste is too large to send to the terminal.")
    }

    @Test("單指滑動每滑過一列送一則 lines:1 的 terminal.scroll(由 herdr 決定捲動方式)")
    func scrollSendsOneMessagePerRow() async {
        let host = FakeHost()
        let model = await Self.connected(host)

        model.scroll(.up, rows: 3, column: 5, row: 4)
        _ = await host.waitForStdin(ofExecution: 0, timeout: Self.timeout) { $0.stdinText.split(separator: "\n").count >= 3 }

        let scrolls = await Self.sentLines(host)
        #expect(scrolls.count == 3)
        #expect(scrolls.allSatisfy {
            $0 == ["type": "terminal.scroll", "direction": "up", "lines": 1, "source": "wheel", "column": 5, "row": 4, "modifiers": 0]
        })
    }

    @Test("沒有開著的連線時，按鍵與貼上不送(也不會丟錯)")
    func inputWithoutConnectionIsDropped() async {
        let host = FakeHost()
        let model = Self.makeModel(host)

        model.press(.escape)
        model.paste("x")

        #expect(!model.isInteractive)
        #expect(await host.executions.isEmpty)
    }

    // MARK: - 字級

    @Test("字級預設 13pt,捏合與 Aa 調整都限制在 8–28pt")
    func fontSizeIsClamped() {
        let model = Self.makeModel(FakeHost())
        #expect(model.fontSize == 13)

        model.setFontSize(40)
        #expect(model.fontSize == 28)
        model.setFontSize(2)
        #expect(model.fontSize == 8)
        model.adjustFontSize(by: 1)
        #expect(model.fontSize == 9)
    }

    // MARK: - 連結

    @Test("只開 http(s) 連結")
    func onlyWebLinksOpen() {
        #expect(PaneTerminalModel.openableURL("https://example.com/a")?.absoluteString == "https://example.com/a")
        #expect(PaneTerminalModel.openableURL("http://example.com") != nil)
        #expect(PaneTerminalModel.openableURL("file:///etc/passwd") == nil)
        #expect(PaneTerminalModel.openableURL("tel:123") == nil)
        #expect(PaneTerminalModel.openableURL("javascript:alert(1)") == nil)
    }
}

/// 去抖用的假 sleep:等待一直卡住，直到 `open()`(時間到)或 task 被取消;`open()` 之後的等待立刻結束。
/// 跟 `RecordingSleeper` 不同的是，`open()` 也會叫醒已經在等的，`completed` 記下沒被取消、真的等滿的次數。
actor SleepGate {
    private(set) var requested: [Duration] = []
    /// 等滿(沒被取消)的次數。
    private(set) var completed = 0
    private var isOpen = false
    private var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextID = 0

    nonisolated var sleep: @Sendable (Duration) async throws -> Void {
        { duration in try await self.wait(duration) }
    }

    func open() {
        isOpen = true
        let resumed = waiting
        waiting = [:]
        resumed.values.forEach { $0.resume() }
    }

    private func wait(_ duration: Duration) async throws {
        requested.append(duration)
        defer { if !Task.isCancelled { completed += 1 } }
        guard !isOpen else { return try Task.checkCancellation() }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                register(continuation, id: id)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// 已經被取消就不等(取消處理可能比登記先跑)。
    private func register(_ continuation: CheckedContinuation<Void, any Error>, id: Int) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            waiting[id] = continuation
        }
    }

    private func cancel(_ id: Int) {
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
