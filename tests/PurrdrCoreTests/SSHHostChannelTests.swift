import Foundation
import NIOCore
import NIOPosix
import PurrdrCore
import Testing

/// 真 SSH 的主機通道，對本機的測試用 SSH 伺服器(只接受 `none` 認證，模擬 Tailscale SSH)。
@Suite("SSH 主機通道")
struct SSHHostChannelTests {
    @Test("以 none 認證登入並執行指令:stdout、stderr、exit code 分開回來")
    func executesCommand() async throws {
        let server = try await TestSSHServer.start { _ in .reply(stdout: "out\n", stderr: "err\n", exitCode: 3) }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint)

        let result = try await collect(channel.execute("anything"))

        #expect(result == Collected(stdout: "out\n", stderr: "err\n", exit: .exit(code: 3)))
        #expect(server.snapshot.commands == ["anything"])
        #expect(server.snapshot.usernames == ["demo"])
        await channel.disconnect()
        await server.stop()
    }

    @Test("stdin 保持開著：寫一行就收到回應，不需要送 EOF(bridge 規則)")
    func stdinStaysOpen() async throws {
        let server = try await TestSSHServer.start { _ in .echoFirstLine }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint)

        let session = try await channel.execute("bridge")
        try await session.write(Data("hello\n".utf8))
        let result = try await collect(session)

        #expect(result.stdout == "echo:hello\n")
        await channel.disconnect()
        await server.stop()
    }

    @Test("被訊號殺死的指令回報 exit-signal,不當成 exit 0")
    func reportsExitSignal() async throws {
        let server = try await TestSSHServer.start { _ in .killed(signal: "KILL") }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint)

        let result = try await collect(channel.execute("x"))

        if case .exit(_, let signal) = result.exit { #expect(signal == "KILL") } else { Issue.record("沒有結束狀態:\(result)") }
        await channel.disconnect()
        await server.stop()
    }

    @Test("沒有 pin:不執行任何指令，回報主機出示的指紋讓使用者確認(TOFU)")
    func unknownHostKeyNeedsConfirmation() async throws {
        let server = try await TestSSHServer.start { _ in .reply() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: nil)

        await #expect(throws: SSHConnectionError.hostKeyUnverified(presented: server.fingerprint)) {
            _ = try await channel.execute("x")
        }
        #expect(server.snapshot.usernames.isEmpty, "還沒確認 host key 就送出了登入")
        #expect(server.snapshot.commands.isEmpty)
        await server.stop()
    }

    @Test("指紋改變：阻擋連線並附上目前出示與已存的指紋")
    func changedHostKeyIsBlocked() async throws {
        let server = try await TestSSHServer.start { _ in .reply() }
        let pinned = HostKeyFingerprint(stored: "COBpO4JIzmE5SXJiDiFEv8QW0IgLEE4H3vB2W6wHLww")!
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: pinned)

        await #expect(throws: SSHConnectionError.hostKeyChanged(presented: server.fingerprint, pinned: pinned)) {
            _ = try await channel.execute("x")
        }
        #expect(server.snapshot.usernames.isEmpty)
        #expect(server.snapshot.commands.isEmpty)
        await server.stop()
    }

    @Test("連線重用：依序與同時的多個指令只建立一條 SSH 連線")
    func reusesOneConnection() async throws {
        let server = try await TestSSHServer.start { _ in .reply(stdout: "ok") }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint)

        try await withThrowingTaskGroup(of: Collected.self) { group in
            for index in 0..<5 { group.addTask { try await collect(channel.execute("c\(index)")) } }
            for try await result in group { #expect(result.stdout == "ok") }
        }
        _ = try await collect(channel.execute("after"))

        #expect(server.snapshot.connections == 1)
        #expect(server.snapshot.commands.count == 6)
        await channel.disconnect()
        await server.stop()
    }

    @Test("連線層失敗的指令不自動重送;下一個指令重新撥號")
    func connectionFailureIsNotRetried() async throws {
        let server = try await TestSSHServer.start { command in command == "send" ? .dropConnection : .reply(stdout: "ok") }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint)

        await #expect(throws: SSHConnectionError.connectionLost) {
            _ = try await collect(channel.execute("send"))
        }
        #expect(server.snapshot.commands == ["send"], "連線層失敗後指令被重送了")

        let next = try await collect(channel.execute("next"))
        #expect(next.stdout == "ok")
        #expect(server.snapshot.connections == 2)
        await channel.disconnect()
        await server.stop()
    }

    @Test("連不上(拒絕連線)回報白話的原因，不是函式庫的錯誤字串")
    func connectionRefused() async throws {
        let server = try await TestSSHServer.start { _ in .reply() }
        let endpoint = server.endpoint
        await server.stop()
        let channel = SSHHostChannel(endpoint: endpoint, hostKeyPin: nil)

        await #expect(throws: SSHConnectionError.connectionRefused) {
            _ = try await channel.execute("x")
        }
    }

    @Test("主機接受 TCP 卻不說 SSH:握手期限到就失敗，不會永遠等", .timeLimit(.minutes(1)))
    func handshakeTimesOut() async throws {
        let silent = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let endpoint = SSHEndpoint(host: "127.0.0.1", port: silent.localAddress!.port!, username: "demo")
        let channel = SSHHostChannel(endpoint: endpoint, hostKeyPin: nil, timeouts: SSHTimeouts(handshake: .milliseconds(300)))

        await #expect(throws: SSHConnectionError.timedOut) {
            _ = try await channel.execute("x")
        }
        try await silent.close()
    }

    @Test("PTY:送 pty-req(term、尺寸)後開 shell;輸入、改尺寸都送到主機")
    func opensPTY() async throws {
        let server = try await TestSSHServer.start { _ in .reply() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint)

        let pty = try await channel.openPTY(PTYRequest(columns: 80, rows: 24))
        var iterator = pty.output.makeAsyncIterator()
        #expect(try await iterator.next() == Data("pty$ ".utf8))
        try await pty.write(Data("ls".utf8))
        #expect(try await iterator.next() == Data("ls".utf8))
        try await pty.resize(columns: 100, rows: 30)
        await pty.close()
        await channel.disconnect()

        try await Task.sleep(for: .milliseconds(100))
        let record = try #require(server.snapshot.ptys.first)
        #expect(record.term == "xterm-256color")
        #expect(record.columns == 80 && record.rows == 24)
        #expect(record.command == nil)
        #expect(record.input == Data("ls".utf8))
        #expect(record.windowChanges == [[100, 30]])
        await server.stop()
    }

    @Test("PTY:shell 自己結束(exit-status)時輸出正常結束;連線斷了則丟 connectionLost")
    func ptyEndsOrLosesConnection() async throws {
        let server = try await TestSSHServer.start { _ in .reply() }
        let channel = SSHHostChannel(endpoint: server.endpoint, hostKeyPin: server.fingerprint)

        let ended = try await channel.openPTY(PTYRequest(columns: 80, rows: 24))
        try await ended.write(Data("exit\r".utf8))
        var received = Data()
        for try await chunk in ended.output { received += chunk }
        #expect(received == Data("pty$ exit\r".utf8))

        let lost = try await channel.openPTY(PTYRequest(columns: 80, rows: 24))
        try await lost.write(Data("drop\r".utf8))
        await #expect(throws: SSHConnectionError.connectionLost) {
            for try await _ in lost.output {}
        }
        await channel.disconnect()
        await server.stop()
    }
}

struct Collected: Equatable {
    var stdout = ""
    var stderr = ""
    var exit: ExecOutput?
}

func collect(_ session: any ExecSession) async throws -> Collected {
    var result = Collected()
    for try await event in session.output {
        switch event {
        case .stdout(let data): result.stdout += String(decoding: data, as: UTF8.self)
        case .stderr(let data): result.stderr += String(decoding: data, as: UTF8.self)
        case .exit: result.exit = event
        }
    }
    return result
}
