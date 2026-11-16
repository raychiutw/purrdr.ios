import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Windows 主機(#6 spike)錄下的 herdr 0.9.5 回應，走和 macOS 相同的解析路徑。
///
/// 守的是：Windows 上 `remote-api-bridge` 與 `terminal session control` 的 wire format 與 macOS 一致，
/// 現有的 `HerdrClient`／`PaneTerminalClient` 不必為 Windows 另寫解析。Windows 的**指令方言**
/// (`-EncodedCommand`、作業系統偵測)不在這裡，屬於 Windows 支援票(#26)。
/// 錄製方式與實測結論見 `docs/research/terminal-session-control-windows.md`。
@Suite("Windows 主機的錄製回應")
struct WindowsHostRecordingTests {
    static let bridge = HerdrCommand.bridge()

    // MARK: - remote-api-bridge

    @Test("ping:Git Bash 直接呼叫與 PowerShell -EncodedCommand 包裝，回應都解出伺服器版本，而且不送 EOF", arguments: [
        "windows/ping.ndjson", "windows/ping.powershell.ndjson",
    ])
    func pingFromWindowsBridge(fixture: String) async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded(fixture))

        #expect(try await HerdrClient(channel: host).ping() == "0.9.5")
        // Windows 的 bridge 在 stdin EOF 時直接放棄請求，連 ping 都不回(實測);macOS 至少還會回 ping。
        #expect(await host.executions.first?.closedStdin == false)
    }

    @Test("Windows 上連不到 socket(Rust 錯誤格式、在地化的系統訊息)→ server_not_running,保留原文")
    func serverNotRunningOnWindows() async throws {
        let stderr = Fixtures.data("windows/error.server-not-running.stderr.txt")
        let host = FakeHost()
        await host.expect(Self.bridge, reply: FakeReply(stderr: stderr, exitCode: 1))

        let error = await #expect(throws: HerdrError.self) { try await HerdrClient(channel: host).ping() }

        guard case .herdr(let code, let message) = error else {
            Issue.record("不是 herdr 錯誤:\(String(describing: error))")
            return
        }
        #expect(code == "server_not_running")
        #expect(message.contains(#"C:\\Users\\demo\\AppData\\Roaming\\herdr\\sessions\\purrdr-nosuch\\herdr.sock"#))
        #expect(message.contains("系統找不到指定的檔案"))
    }

    @Test("JSON 無效的請求:錯誤 envelope 的碼與原文和 macOS 相同")
    func invalidRequestEnvelope() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("windows/error.invalid-request.ndjson"))

        await #expect(throws: HerdrError.herdr(
            code: "invalid_request", message: "invalid request: key must be a string at line 1 column 37"
        )) {
            try await HerdrClient(channel: host).ping()
        }
    }

    @Test("events.subscribe:ack 之後的 workspace_closed 事件")
    func workspaceClosedEvent() async throws {
        let host = FakeHost()
        await host.expect(Self.bridge, reply: .recorded("windows/events.workspace-closed.ndjson", keepsOpen: true))

        let stream = try await HerdrClient(channel: host).subscribe([.init(.workspaceClosed)])
        var events: [HerdrEvent] = []
        for try await event in stream {
            events.append(event)
            if events.count == 2 { break }
        }

        #expect(events == [.subscriptionStarted, .event(name: "workspace_closed", paneID: nil)])
    }

    // MARK: - terminal session control

    static func connect(_ host: FakeHost) async throws -> PaneTerminalConnection {
        await host.expect(
            HerdrCommand.terminalSessionControl(target: "w2:p1", columns: 40, rows: 12), reply: FakeReply(keepsOpen: true)
        )
        return try await PaneTerminalClient(channel: host).control(target: "w2:p1", columns: 40, rows: 12)
    }

    static func replay(_ fixture: String) async throws -> [PaneTerminalEvent] {
        let host = FakeHost()
        let connection = try await connect(host)
        for line in Fixtures.sessionControlLines(fixture, host: .windows) {
            await host.send(.stdout(line + [0x0A]), toExecution: 0)
        }
        await host.finish(execution: 0)
        var events: [PaneTerminalEvent] = []
        for await event in connection.events { events.append(event) }
        return events
    }

    static func frames(_ events: [PaneTerminalEvent]) -> [TerminalFrame] {
        events.compactMap { if case .frame(let frame) = $0 { frame } else { nil } }
    }

    @Test("handshake、回顯、release:Git Bash 與 PowerShell 包裝的串流都解出 frame 並以 detached 結束", arguments: [
        "01-handshake-echo-release.stdout.ndjson", "01ps-handshake-echo-release.stdout.ndjson",
    ])
    func handshakeEchoRelease(fixture: String) async throws {
        let events = try await Self.replay(fixture)
        let frames = Self.frames(events)

        #expect(frames.map(\.seq) == Array(1...UInt64(frames.count)))
        #expect(frames.first?.full == true)
        #expect(frames.dropFirst().allSatisfy { !$0.full })
        #expect(frames.allSatisfy { $0.columns == 40 && $0.rows == 12 })
        // PowerShell 的 prompt 與 `Write-Output ('hello-' + 'world')` 的輸出。
        #expect(String(decoding: frames[0].bytes, as: UTF8.self).contains(#"PS C:\Windows\Temp>"#))
        #expect(frames.contains { String(decoding: $0.bytes, as: UTF8.self).contains("hello-world") })
        #expect(events.last == .closed(.detached))
    }

    @Test("resize:每次改尺寸都回新尺寸的 full frame(ConPTY 也跟著改，見研究筆記)")
    func resizeFullFrames() async throws {
        let frames = Self.frames(try await Self.replay("02-resize.stdout.ndjson"))

        let fullSizes = frames.filter(\.full).map { "\($0.columns)x\($0.rows)" }
        #expect(fullSizes == ["40x12", "60x15", "30x10"])
        #expect(frames.last.map { "\($0.columns)x\($0.rows)" } == "30x10")
    }

    @Test("中文、組合字元、emoji 與 256 色經 ConPTY 後原樣出現在 frame bytes")
    func unicodeThroughConPTY() async throws {
        let frames = Self.frames(try await Self.replay("07-unicode-colors.stdout.ndjson"))
        let bytes = frames.reduce(Data(), { $0 + $1.bytes })
        let text = String(decoding: bytes, as: UTF8.self)

        #expect(text.contains("中"))
        #expect(text.contains("e\u{301}"))
        #expect(text.contains("🙂"))
        // `Write-Host red -ForegroundColor Red` → 調色盤 9 號
        #expect(text.contains("\u{1B}[0;38;5;9;49mred"))
    }

    @Test("terminal.closed 的原文在 Windows 與 macOS 相同，分類一致", arguments: [
        ("06-takeover-B.stdout.ndjson", TerminalCloseReason.alreadyAttached),
        ("06-takeover-A.stdout.ndjson", .takenOver),
        ("06-takeover-C.stdout.ndjson", .detached),
        ("13-not-found-control.stdout.ndjson", .notFound),
        ("13ps-not-found-control.stdout.ndjson", .notFound),
        ("13-not-found-observe.stdout.ndjson", .notFound),
        ("14-exited-control.stdout.ndjson", .exited),
        ("14-exited-observer.stdout.ndjson", .exited),
        ("10-stdin-eof-release.stdout.ndjson", .detached),
        ("10ps-stdin-eof-release.stdout.ndjson", .detached),
        ("12-kill-gb-reattach-1s.stdout.ndjson", .detached),
        ("12-kill-ps-reattach-1s.stdout.ndjson", .detached),
    ])
    func closeReasons(fixture: String, reason: TerminalCloseReason) async throws {
        #expect(try await Self.replay(fixture).last == .closed(reason))
    }

    @Test("超過 1 MiB 的單則輸入:沒有 terminal.closed 就 EOF → 連線中斷(和 macOS 相同)")
    func oversizeInputDisconnects() async throws {
        let events = try await Self.replay("11-oversize-input-disconnect.stdout.ndjson")

        #expect(events.last == .disconnected)
        #expect(Self.frames(events).count == events.count - 1)
    }
}
