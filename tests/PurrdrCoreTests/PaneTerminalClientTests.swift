import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Pane 終端機協定(`herdr terminal session control`)。資料一律是 #4 spike 從真實主機錄下的 NDJSON。
@Suite("Pane 終端機協定")
struct PaneTerminalClientTests {
    static func control(_ target: String = "w1:p1", columns: Int = 40, rows: Int = 12, takeover: Bool = false) -> String {
        HerdrCommand.terminalSessionControl(target: target, columns: columns, rows: rows, takeover: takeover)
    }

    /// 把錄製檔的 stdout 逐行送進假主機，最後 EOF。
    static func replay(_ fixture: String, on host: FakeHost, execution: Int = 0, finish: Bool = true) async {
        for line in Fixtures.sessionControlLines(fixture) {
            await host.send(.stdout(line + [0x0A]), toExecution: execution)
        }
        if finish { await host.finish(execution: execution) }
    }

    static func collect(_ connection: PaneTerminalConnection) async -> [PaneTerminalEvent] {
        var events: [PaneTerminalEvent] = []
        for await event in connection.events { events.append(event) }
        return events
    }

    @Test("開 Pane 終端機時以 control 指令帶入 target 與格數，不帶 --takeover")
    func controlCommand() {
        #expect(Self.control("w1:p1", columns: 80, rows: 24) ==
            #"PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH" 'herdr' terminal session control 'w1:p1' --cols 80 --rows 24"#)
        #expect(Self.control("w1:p1", columns: 80, rows: 24, takeover: true).hasSuffix(" --cols 80 --rows 24 --takeover"))
    }

    @Test("錄製的 frame 依序解出(seq、尺寸、full、base64 解開的畫面 bytes),release 後收到 detached")
    func framesFromFixture() async throws {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(trigger: .manual))
        let connection = try await PaneTerminalClient(channel: host).control(target: "w1:p1", columns: 40, rows: 12)

        await Self.replay("01-handshake-echo-release.stdout.ndjson", on: host)
        let events = await Self.collect(connection)

        let frames = events.compactMap { if case .frame(let frame) = $0 { frame } else { nil } }
        #expect(frames.map(\.seq) == [1, 2, 3])
        #expect(frames.map(\.full) == [true, false, false])
        #expect(frames.allSatisfy { $0.columns == 40 && $0.rows == 12 })
        // 第三個 frame 是 `echo hello-""world` 的回顯與輸出。
        #expect(String(decoding: frames[2].bytes, as: UTF8.self).contains("hello-world"))
        #expect(events.last == .closed(.detached))
    }

    @Test("terminal.closed 的原文依實測分類：被拒、被接管、找不到、程式結束", arguments: [
        ("06-takeover-B.stdout.ndjson", TerminalCloseReason.alreadyAttached),
        ("06-takeover-A.stdout.ndjson", .takenOver),
        ("13-not-found-control.stdout.ndjson", .notFound),
        ("14-exited-control.stdout.ndjson", .exited),
        ("10-stdin-eof-release.stdout.ndjson", .detached),
    ])
    func closeReasons(fixture: String, reason: TerminalCloseReason) async throws {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(trigger: .manual))
        let connection = try await PaneTerminalClient(channel: host).control(target: "w1:p1", columns: 40, rows: 12)

        await Self.replay(fixture, on: host)

        #expect(await Self.collect(connection).last == .closed(reason))
    }

    @Test("沒認得的原因保留 herdr 原文")
    func unknownReasonKeepsText() {
        #expect(TerminalCloseReason(herdr: "server is shutting down") == .other("server is shutting down"))
    }

    @Test("stdout EOF 但沒有 terminal.closed(超大輸入、controller 被殺)→ 連線中斷，exit 0 也一樣", arguments: [
        "11-oversize-input-disconnect.stdout.ndjson", "12-sigkill-then-reattach.stdout.ndjson",
    ])
    func eofWithoutClosedIsDisconnect(fixture: String) async throws {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(trigger: .manual))
        let connection = try await PaneTerminalClient(channel: host).control(target: "w1:p1", columns: 40, rows: 12)

        await Self.replay(fixture, on: host)
        let events = await Self.collect(connection)

        #expect(events.last == .disconnected)
        #expect(events.dropLast().allSatisfy { if case .frame = $0 { true } else { false } })
    }

    @Test("herdr 沒跑起來(找不到指令)→ 失敗並帶 stderr,不是連線中斷")
    func herdrMissingFails() async throws {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(stderr: Data("sh: herdr: command not found\n".utf8), exitCode: 127))
        let connection = try await PaneTerminalClient(channel: host).control(target: "w1:p1", columns: 40, rows: 12)

        #expect(await Self.collect(connection) == [.failed(exitCode: 127, message: "sh: herdr: command not found")])
    }

    @Test("輸入、resize、捲動、release 的格式與 spike 實際送給 herdr 的訊息相同")
    func inputWireFormat() async throws {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(trigger: .manual))
        let connection = try await PaneTerminalClient(channel: host).control(target: "w1:p1", columns: 40, rows: 12)

        try await connection.send(bytes: Data([0x15]))
        try await connection.send(.resize(columns: 60, rows: 15))
        try await connection.send(.scroll(.down, lines: 2, column: 0, row: 0))
        await connection.release()

        let sent = await host.executions[0].stdinText.split(separator: "\n").map(Self.json)
        let recorded = [
            #"{"type": "terminal.input", "bytes": "FQ=="}"#,
            #"{"type": "terminal.resize", "cols": 60, "rows": 15, "cell_width_px": 0, "cell_height_px": 0}"#,
            #"{"type": "terminal.scroll", "direction": "down", "lines": 2, "source": "wheel", "column": 0, "row": 0, "modifiers": 0}"#,
            #"{"type": "terminal.release"}"#,
        ]
        // 錄製檔裡確實有這幾行(不是照程式碼手寫的期望值)。
        let fixtureLines = Set(["02-resize.stdin.ndjson", "03-scroll-host-scrollback.stdin.ndjson"].flatMap {
            Fixtures.sessionControlLines($0).map { String(decoding: $0, as: UTF8.self) }
        })
        #expect(recorded.allSatisfy(fixtureLines.contains))
        #expect(sent == recorded.map(Self.json))
        #expect(await host.executions[0].closedStdin)
    }

    @Test("大量輸入切成每則 ≤ 64 KiB,串起來等於原文(herdr 收到 > 1 MiB 的單則會斷線)")
    func largeInputIsChunked() async throws {
        let host = FakeHost()
        await host.expect(Self.control(), reply: FakeReply(trigger: .manual))
        let connection = try await PaneTerminalClient(channel: host).control(target: "w1:p1", columns: 40, rows: 12)
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 % 95 + 32) })

        try await connection.send(bytes: payload)

        let chunks = await host.executions[0].stdinText.split(separator: "\n").map {
            Data(base64Encoded: Self.json($0)["bytes"] as? String ?? "") ?? Data()
        }
        #expect(chunks.count == 4)
        #expect(chunks.allSatisfy { $0.count <= 64 * 1024 })
        #expect(chunks.reduce(Data(), +) == payload)
    }

    static func json(_ line: some StringProtocol) -> NSDictionary {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? NSDictionary ?? [:]
    }
}
