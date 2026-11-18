import Foundation
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 主機檔案的定期讀取改走長駐通道(#203):主題、註記、用量共用每台主機一條，腳本只送一次，沒變只回 `unchanged`。
@Suite("主機檔案的長駐讀取")
struct HostFilesLongRunningTests {
    static let theme: HostPath = ".config/herdr/config.toml"
    static let usage: HostPath = ".purrdr/claude-usage/usage.json"

    static func followingHost(channels count: Int = 1, command: String = HostFileScript.follow()) async -> FakeHost {
        let host = FakeHost()
        for _ in 0..<count {
            await host.expect(command, reply: FakeReply(keepsOpen: true))
        }
        return host
    }

    static func reply(_ lines: String) -> Data {
        Data(("purrdr-files 1\nuser demo\n" + lines + "end\n").utf8)
    }

    /// 在背景讀(等主機回應)。
    static func reading(_ files: HostFiles, _ paths: [HostPath], known: [HostPath: HostFileVersion] = [:]) -> Task<HostFileRead, any Error> {
        Task { try await files.read(paths, knownVersions: known) }
    }

    @Test("沒變時只送一行「路徑 已知版本」、收 unchanged;再讀一次還是同一條通道")
    func unchangedOverOneChannel() async throws {
        let host = await Self.followingHost()
        let files = HostFiles(channel: host, readsOverLongRunningChannel: true)
        let known = [Self.theme: HostFileVersion(checksum: "11:5")]

        let first = Self.reading(files, [Self.theme], known: known)
        try #require(await host.waitForStdin(ofExecution: 0) { $0.stdinText == ".config/herdr/config.toml 11:5\n" })
        await host.send(stdout: Self.reply("unchanged 0\n"), toExecution: 0)
        #expect(try await first.value.unchanged == [Self.theme])

        let second = Self.reading(files, [Self.theme, Self.usage], known: known)
        try #require(await host.waitForStdin(ofExecution: 0) { $0.stdinText.hasSuffix("\n.config/herdr/config.toml 11:5 .purrdr/claude-usage/usage.json -\n") })
        await host.send(stdout: Self.reply("unchanged 0\nmissing 1\n"), toExecution: 0)
        let read = try await second.value

        #expect(read.unchanged == [Self.theme])
        #expect(read[Self.usage] == .missing)
        #expect(await host.executions.count == 1)
        #expect(await host.executions.first?.closedStdin == false, "stdin 要留著送下一個請求")
    }

    @Test("有變：回傳新內容與版本;內容裡有 end 行也照宣告的長度讀完")
    func changedContentsMayContainEndLine() async throws {
        let host = await Self.followingHost()
        let files = HostFiles(channel: host, readsOverLongRunningChannel: true)

        let reading = Self.reading(files, [Self.theme], known: [Self.theme: HostFileVersion(checksum: "11:5")])
        try #require(await host.waitForStdin(ofExecution: 0) { !$0.stdin.isEmpty })
        await host.send(stdout: Self.reply("file 0 22:6 6\nx\nend\n\n"), toExecution: 0)

        #expect(try await reading.value[Self.theme] == .file(Data("x\nend\n".utf8), version: HostFileVersion(checksum: "22:6")))
    }

    @Test("通道結束(自我時限 exit 124)後，下一次讀重開通道")
    func reopensAfterTimeLimit() async throws {
        let host = await Self.followingHost(channels: 2)
        let files = HostFiles(channel: host, readsOverLongRunningChannel: true)
        let first = Self.reading(files, [Self.theme])
        try #require(await host.waitForStdin(ofExecution: 0) { !$0.stdin.isEmpty })
        await host.send(stdout: Self.reply("missing 0\n"), toExecution: 0)
        _ = try await first.value
        await host.finish(execution: 0, exitCode: 124)

        let second = Self.reading(files, [Self.theme])
        #expect(await host.waitForExecutions(2) == 2)
        try #require(await host.waitForStdin(ofExecution: 1) { $0.stdinText == ".config/herdr/config.toml -\n" })
        await host.send(stdout: Self.reply("missing 0\n"), toExecution: 1)

        #expect(try await second.value[Self.theme] == .missing)
        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("主機跑不了長駐腳本(還沒回應就 exit 127):這次與之後都退回一次性的條件式讀取")
    func unsupportedHostFallsBackToOneShotRead() async throws {
        let host = FakeHost()
        await host.expect(HostFileScript.follow(), reply: FakeReply(stderr: Data("sh: not found\n".utf8), exitCode: 127))
        let oneShot = HostFileScript.command(HostFileScript.readIfChanged, arguments: [Self.theme.relative, "11:5"])
        for _ in 0..<2 {
            await host.expect(oneShot, reply: FakeReply(stdout: Data("purrdr-files 1\nuser demo\nunchanged 0\n".utf8)))
        }
        let files = HostFiles(channel: host, readsOverLongRunningChannel: true)
        let known = [Self.theme: HostFileVersion(checksum: "11:5")]

        #expect(try await files.read([Self.theme], knownVersions: known).unchanged == [Self.theme])
        #expect(try await files.read([Self.theme], knownVersions: known).unchanged == [Self.theme])
        #expect(await host.executions.map(\.command) == [HostFileScript.follow(), oneShot, oneShot])
    }

    @Test("主題與註記共用同一條長駐通道")
    func themeAndNotesShareOneChannel() async throws {
        let host = await Self.followingHost()
        let files = HostFiles(channel: host, readsOverLongRunningChannel: true)
        let store: HostPath = ".claude/plugins/store/cc-plugin-you-should-know_builtin-0123456789ab.json"
        let theme = Task { try await HostThemeHost(channel: host, files: files).readTheme(ifChangedFrom: HostFileVersion(checksum: "11:5")) }
        try #require(await host.waitForStdin(ofExecution: 0) { $0.stdinText.components(separatedBy: "\n").count == 2 })
        await host.send(stdout: Self.reply("unchanged 0\nunchanged 1\n"), toExecution: 0)
        #expect(try await theme.value == .unchanged)

        let notes = Task { try await YouShouldKnowHost(channel: host, files: files).read(store, ifChangedFrom: HostFileVersion(checksum: "33:7")) }
        try #require(await host.waitForStdin(ofExecution: 0) { $0.stdinText.hasSuffix("\n\(store.relative) 33:7\n") })
        await host.send(stdout: Self.reply("unchanged 0\n"), toExecution: 0)

        guard case .unchanged = try await notes.value else {
            Issue.record("註記應該是 unchanged")
            return
        }
        #expect(await host.executions.count == 1)
    }

    @Test("Windows 主機：stub 與 PowerShell 腳本只送一次、不送 EOF,之後同一個 stdin 只送請求行")
    func windowsUploadsScriptOnce() async throws {
        let host = await Self.followingHost(command: WindowsHostScriptsTests.stub)
        let files = HostFiles(channel: WindowsHostChannel(host), readsOverLongRunningChannel: true)
        let known = [Self.theme: HostFileVersion(checksum: "ab:5")]
        let windowsReply = Data("purrdr-files 1\nuser demo\nhome C:/Users/demo\nunchanged 0\nend\n".utf8)

        for round in 1...2 {
            let reading = Self.reading(files, [Self.theme], known: known)
            try #require(await host.waitForStdin(ofExecution: 0) { $0.stdinText.components(separatedBy: "\n.config/herdr/config.toml ab:5\n").count == round + 1 })
            await host.send(stdout: windowsReply, toExecution: 0)
            let read = try await reading.value
            #expect(read.unchanged == [Self.theme])
            #expect(read.isWindows)
        }

        let stdin = try #require(await host.executions.first?.stdinText)
        #expect(stdin.components(separatedBy: "#purrdr-end-of-script").count == 2, "腳本只送一次")
        #expect(stdin.contains("\n$a=@('60','600')\n"))
        #expect(!stdin.contains("cksum"), "POSIX 腳本不能送到 Windows")
        #expect(await host.executions.count == 1)
        #expect(await host.executions.first?.closedStdin == false)
    }

    // MARK: - 主機腳本(本機 /bin/sh 實跑)

    #if os(macOS)
    @Test("主機腳本：一條通道多次讀，沒變回 unchanged、有變回新內容、不存在回 missing")
    func scriptAnswersOverOneChannel() async throws {
        let host = try LocalShellHost.temporary(feedsStdin: true)
        try host.write(Data("[theme]\nname = \"dracula\"\n".utf8), to: Self.theme.relative)
        let files = HostFiles(channel: host, readsOverLongRunningChannel: true)

        let first = try await files.read([Self.theme, Self.usage])
        guard case .file(let contents, let version)? = first[Self.theme] else {
            Issue.record("讀不到主題：\(first)")
            return
        }
        let unchanged = try await files.read([Self.theme], knownVersions: [Self.theme: version])
        try host.write(Data("[theme]\nname = \"nord\"\nend\n".utf8), to: Self.theme.relative)
        let changed = try await files.read([Self.theme], knownVersions: [Self.theme: version])

        #expect(contents == Data("[theme]\nname = \"dracula\"\n".utf8))
        #expect(first[Self.usage] == .missingDirectory)
        #expect(first.user == NSUserName())
        #expect(unchanged.unchanged == [Self.theme])
        #expect(changed[Self.theme]?.contents == Data("[theme]\nname = \"nord\"\nend\n".utf8))
        #expect(host.commands == [HostFileScript.follow()], "只開一條通道")
    }

    @Test("主機腳本：閒置時限到了以 exit 124 結束，不留下程序")
    func scriptIdleLimit() async throws {
        let marker = "purrdr-test-\(UUID().uuidString)"
        let host = try LocalShellHost.temporary(feedsStdin: true)
        let started = ContinuousClock.now
        let session = try await host.execute(HostFileScript.follow(idleSeconds: 2, totalSeconds: 60) + " " + marker)
        try await session.write(Data("\(Self.theme.relative) -\n".utf8))
        let output = try await session.collectOutput()
        let elapsed = ContinuousClock.now - started
        try await Task.sleep(for: .seconds(2))

        #expect(output.exitCode == 124, "stderr: \(String(decoding: output.stderr, as: UTF8.self))")
        #expect(output.stdoutText.hasSuffix("missing 0\nend\n") || output.stdoutText.hasSuffix("nodir 0\nend\n"), "請求照常回應")
        #expect(elapsed < .seconds(20))
        #expect(SSHTranscriptFollowerTests.processes(containing: marker).isEmpty)
    }

    @Test("用量：第二次讀帶上次的版本，沒變時沿用上次的結果")
    func usageReadsConditionally() async throws {
        let host = try LocalShellHost.temporary()
        try host.write(Data(#"{"captured_at":1760000000,"status_line_input":{"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1760003600}}}}"#.utf8), to: Self.usage.relative)
        let usage = ClaudePlanUsageHost(channel: host)

        let first = try await usage.readPlanUsage()
        let second = try await usage.readPlanUsage()

        #expect(first?.fiveHour?.usedPercentage == 23.5)
        #expect(second == first)
        guard case .readIfChanged(_, let known)? = host.commands.last.flatMap(HostFileRequest.init(command:)) else {
            Issue.record("第二次不是條件式讀取：\(host.commands)")
            return
        }
        #expect(known[Self.usage] != nil)
    }
    #endif
}
