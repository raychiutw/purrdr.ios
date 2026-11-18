import Foundation
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// SSH 的對話紀錄追蹤改成長駐腳本(#166,spec #154 方案 B):一條 exec 通道服務所有路徑，沒變不送事件。
@Suite("SSH 長駐追蹤腳本")
struct SSHTranscriptFollowerTests {
    static let path = "/Users/demo/.claude/projects/-Users-demo-Projects-ledger/0000c1a0-0000-4000-8000-000000000001.jsonl"
    static let otherPath = "/Users/demo/.claude/projects/-Users-demo-Projects-ledger/0000c1a0-0000-4000-8000-000000000002.jsonl"
    static let secondLine = #"{"n":2}"#

    /// 只有 `wake()` 才讀。
    static func manualPace() -> TranscriptFollowPace {
        TranscriptFollowPace(interval: .seconds(2), sleep: RecordingSleeper().sleep)
    }

    /// 預期 app 開 `count` 次長駐追蹤腳本，每次都保持開著。
    static func followingHost(channels count: Int = 1) async -> FakeHost {
        let host = FakeHost()
        for _ in 0..<count {
            await host.expect(TranscriptCommand.follow(), reply: FakeReply(keepsOpen: true))
        }
        return host
    }

    /// 主機回「讀到新增」:大小、版本，接著每行「原始長度 TAB 行」,最後「end 新游標 錨點」。
    static func appendedReply(size: Int, stamp: String, lines: [String], end: Int, anchor: String) -> Data {
        Data((["appended \(size) \(stamp)"] + lines.map { "\($0.utf8.count)\t\($0)" } + ["end \(end) \(anchor)"]).map { $0 + "\n" }.joined().utf8)
    }

    /// 在背景等下一則事件(拿到後串流就放掉，追蹤隨之結束)。
    static func nextEvent(_ stream: AsyncThrowingStream<TranscriptFollowEvent, any Error>) -> Task<TranscriptFollowEvent?, any Error> {
        Task {
            var events = stream.makeAsyncIterator()
            return try await events.next()
        }
    }

    // MARK: - adapter(假主機)

    @Test("沒變時不送事件;下一輪有新增才送 appended")
    func unchangedSendsNoEvent() async throws {
        let host = await Self.followingHost()
        let pace = Self.manualPace()
        let next = Self.nextEvent(await SSHHostConnection(channel: host).followTranscript(path: Self.path, from: 8, pace: pace))

        pace.wake()
        #expect(await host.waitForStdin(ofExecution: 0) { $0.stdinText == "8 - - \(Self.path)\n" })
        await host.send(stdout: Data("unchanged\n".utf8), toExecution: 0)
        pace.wake()
        #expect(await host.waitForStdin(ofExecution: 0) { $0.stdinText.components(separatedBy: "\n").count == 3 })
        await host.send(stdout: Self.appendedReply(size: 16, stamp: "1700000000-16", lines: [Self.secondLine], end: 16, anchor: "4242"), toExecution: 0)

        #expect(try await next.value == .appended(TranscriptChunk(start: 8, end: 16, lines: [Self.secondLine])))
        #expect(await host.executions.count == 1)
    }

    @Test("有新增送 appended;下一輪從新游標、帶主機給的版本與錨點")
    func appendedThenContinuesFromNewCursor() async throws {
        let host = await Self.followingHost()
        let pace = Self.manualPace()
        var events = await SSHHostConnection(channel: host).followTranscript(path: Self.path, from: 8, pace: pace).makeAsyncIterator()

        pace.wake()
        #expect(await host.waitForStdin(ofExecution: 0) { $0.stdinText == "8 - - \(Self.path)\n" })
        await host.send(stdout: Self.appendedReply(size: 16, stamp: "1700000000-16", lines: [Self.secondLine], end: 16, anchor: "4242"), toExecution: 0)
        let event = try await events.next()
        pace.wake()

        #expect(event == .appended(TranscriptChunk(start: 8, end: 16, lines: [Self.secondLine])))
        #expect(await host.waitForStdin(ofExecution: 0) { $0.stdinText.hasSuffix("\n16 1700000000-16 4242 \(Self.path)\n") })
    }

    @Test("落後超過追趕上限(主機只讀了一部分):下一輪不帶版本，主機接著送剩下的，不回 unchanged")
    func partialReadOmitsStamp() async throws {
        let host = await Self.followingHost()
        let pace = Self.manualPace()
        var events = await SSHHostConnection(channel: host).followTranscript(path: Self.path, from: 8, pace: pace).makeAsyncIterator()

        pace.wake()
        #expect(await host.waitForStdin(ofExecution: 0) { !$0.stdin.isEmpty })
        await host.send(stdout: Self.appendedReply(size: 2_000_000, stamp: "1700000000-2000000", lines: [Self.secondLine], end: 16, anchor: "4242"), toExecution: 0)
        _ = try await events.next()
        pace.wake()

        #expect(await host.waitForStdin(ofExecution: 0) { $0.stdinText.hasSuffix("\n16 - 4242 \(Self.path)\n") })
    }

    @Test("檔案被換掉:送 replaced(新檔大小),追蹤結束")
    func replacedEndsFollowing() async throws {
        let host = await Self.followingHost()
        let pace = Self.manualPace()
        let stream = await SSHHostConnection(channel: host).followTranscript(path: Self.path, from: 16, pace: pace)
        let events = Task {
            var collected: [TranscriptFollowEvent] = []
            for try await event in stream { collected.append(event) }
            return collected
        }

        pace.wake()
        #expect(await host.waitForStdin(ofExecution: 0) { !$0.stdin.isEmpty })
        await host.send(stdout: Data("replaced 3\n".utf8), toExecution: 0)

        #expect(try await events.value == [.replaced(size: 3)])
    }

    @Test("通道結束(自我時限 exit 124):下一輪重開通道，從保留的游標接著讀")
    func reopensChannelKeepingCursor() async throws {
        let host = await Self.followingHost(channels: 2)
        let pace = Self.manualPace()
        var events = await SSHHostConnection(channel: host).followTranscript(path: Self.path, from: 8, pace: pace).makeAsyncIterator()

        pace.wake()
        #expect(await host.waitForStdin(ofExecution: 0) { !$0.stdin.isEmpty })
        await host.send(stdout: Self.appendedReply(size: 16, stamp: "1700000000-16", lines: [Self.secondLine], end: 16, anchor: "4242"), toExecution: 0)
        _ = try await events.next()
        await host.finish(execution: 0, exitCode: 124)
        pace.wake()

        #expect(await host.waitForExecutions(2) == 2)
        #expect(await host.waitForStdin(ofExecution: 1) { $0.stdinText == "16 1700000000-16 4242 \(Self.path)\n" })
        #expect(await host.unmetExpectations.isEmpty)
    }

    @Test("同時追蹤兩個路徑:只開一條通道，兩個請求都送進同一條")
    func onlyOneChannelForAllPaths() async throws {
        let host = await Self.followingHost()
        let connection = SSHHostConnection(channel: host)
        let firstPace = Self.manualPace()
        let secondPace = Self.manualPace()
        let first = Self.nextEvent(await connection.followTranscript(path: Self.path, from: 8, pace: firstPace))
        let second = Self.nextEvent(await connection.followTranscript(path: Self.otherPath, from: 20, pace: secondPace))
        defer {
            first.cancel()
            second.cancel()
        }

        firstPace.wake()
        secondPace.wake()
        #expect(await host.waitForStdin(ofExecution: 0) { $0.stdinText.contains("8 - - \(Self.path)\n") })
        await host.send(stdout: Data("unchanged\n".utf8), toExecution: 0)
        #expect(await host.waitForStdin(ofExecution: 0) { $0.stdinText.contains("20 - - \(Self.otherPath)\n") })

        #expect(await host.executions.count == 1)
    }

    @Test("呼叫端不再讀:之後不再送請求，最後一個追蹤結束時關閉通道")
    func stoppingSendsNothingMore() async throws {
        let host = await Self.followingHost()
        let pace = Self.manualPace()
        let next = Self.nextEvent(await SSHHostConnection(channel: host).followTranscript(path: Self.path, from: 8, pace: pace))

        pace.wake()
        #expect(await host.waitForStdin(ofExecution: 0) { !$0.stdin.isEmpty })
        await host.send(stdout: Data("unchanged\n".utf8), toExecution: 0)
        next.cancel()
        _ = try? await next.value

        #expect(await host.waitUntilClosed(execution: 0))
        pace.wake()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await host.executions.map(\.stdinText) == ["8 - - \(Self.path)\n"])
    }

    @Test("主機跑不了追蹤腳本(Demo 主機回 127):退回分段接著讀的輪詢")
    func hostWithoutScriptFallsBackToPolling() async throws {
        let host = FakeHost()
        await host.expect(TranscriptCommand.follow(), reply: FakeReply(stderr: Data("sh: not found\n".utf8), exitCode: 127))
        await host.expect(
            TranscriptCommand.catchUp(path: Self.path, from: 8, limit: TranscriptReader.catchUpLimit),
            reply: FakeReply(stdout: Data("16\n7\t\(Self.secondLine)\n".utf8)))
        let pace = Self.manualPace()
        let next = Self.nextEvent(await SSHHostConnection(channel: host).followTranscript(path: Self.path, from: 8, pace: pace))

        pace.wake()

        #expect(try await next.value == .appended(TranscriptChunk(start: 8, end: 16, lines: [Self.secondLine])))
    }

    @Test("Windows 主機(#167):一條 PowerShell 長駐通道,stdin 先送腳本與結束標記、不送 EOF,接著同一個 stdin 送請求行")
    func windowsHostFollowsOverStdin() async throws {
        let host = FakeHost()
        await host.expect(WindowsHostScriptsTests.stub, reply: FakeReply(keepsOpen: true))
        let pace = Self.manualPace()
        let path = WindowsHostScriptsTests.path
        let next = Self.nextEvent(await SSHHostConnection(channel: WindowsHostChannel(host)).followTranscript(path: path, from: 43, pace: pace))
        defer { next.cancel() }

        pace.wake()
        try #require(await host.waitForStdin(ofExecution: 0) { $0.stdinText.hasSuffix("\n#purrdr-end-of-script\n43 - - \(path)\n") })
        await host.send(stdout: Data("unchanged\n".utf8), toExecution: 0)
        pace.wake()
        try #require(await host.waitForStdin(ofExecution: 0) { $0.stdinText.components(separatedBy: "\n43 - - ").count == 3 })
        let lines = [#"{"type":"assistant","n":2,"image":""}"#, #"{"type":"user","n":3}"#]
        await host.send(
            stdout: Self.appendedReply(size: 303, stamp: "638000000000000000-303", lines: lines, end: 303, anchor: "0a1b2c3d4e5f6071"),
            toExecution: 0)

        #expect(try await next.value == .appended(TranscriptChunk(start: 43, end: 303, lines: lines)))
        #expect(await host.executions.count == 1)
        #expect(await host.executions.first?.closedStdin == false, "stdin 要留著送請求行")
    }

    // MARK: - 主機腳本(本機 /bin/sh 實跑)

    #if os(macOS)
    static let relativePath = ".claude/projects/-Users-demo-Projects-ledger/0000c1a0-0000-4000-8000-000000000001.jsonl"
    static let firstLine = #"{"n":1}"#

    static func line(_ text: String) -> Data { Data((text + "\n").utf8) }

    /// 讓檔案的修改時間明顯不同(同一秒內換檔，版本比對看不出來)。
    static func touchLater(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: url.path(percentEncoded: false))
    }

    struct LocalFollow {
        let host: LocalShellHost
        let url: URL
        let pace: TranscriptFollowPace
        let events: AsyncThrowingStream<TranscriptFollowEvent, any Error>
    }

    /// 本機 `/bin/sh` 跑追蹤腳本，從第一行之後開始追蹤。
    static func localFollow() async throws -> LocalFollow {
        let host = try LocalShellHost.temporary(feedsStdin: true)
        let url = try host.write(line(firstLine), to: relativePath)
        let pace = manualPace()
        let events = await SSHHostConnection(channel: host).followTranscript(path: url.path(percentEncoded: false), from: 8, pace: pace)
        return LocalFollow(host: host, url: url, pace: pace, events: events)
    }

    @Test("主機腳本：附加的完整行送 appended,圖片字串剝掉，原始長度照實算游標")
    func scriptAppendsAndStripsImages() async throws {
        let follow = try await Self.localFollow()
        var events = follow.events.makeAsyncIterator()
        let image = #"{"image":""# + String(repeating: "A", count: 200) + #""}"#

        try follow.host.append(Self.line(image) + Data(#"{"partial":"#.utf8), to: Self.relativePath)
        follow.pace.wake()
        let event = try await events.next()

        #expect(event == .appended(TranscriptChunk(start: 8, end: 8 + image.utf8.count + 1, lines: [#"{"image":""}"#])))
        #expect(follow.host.commands == [TranscriptCommand.follow()], "只開一條通道")
    }

    @Test("主機腳本：檔案變短送 replaced")
    func scriptReportsShrink() async throws {
        let follow = try await Self.localFollow()
        var events = follow.events.makeAsyncIterator()

        try follow.host.write(Self.line("{}"), to: Self.relativePath)
        follow.pace.wake()

        #expect(try await events.next() == .replaced(size: 3))
    }

    @Test("主機腳本：換成同長的新檔(游標前的錨點不同)送 replaced")
    func scriptReportsSameLengthReplacement() async throws {
        let follow = try await Self.localFollow()
        var events = follow.events.makeAsyncIterator()
        try follow.host.append(Self.line(Self.secondLine), to: Self.relativePath)
        follow.pace.wake()
        _ = try await events.next()

        try follow.host.write(Self.line(#"{"m":1}"#) + Self.line(#"{"m":2}"#), to: Self.relativePath)
        try Self.touchLater(follow.url)
        follow.pace.wake()

        #expect(try await events.next() == .replaced(size: 16))
    }

    @Test("主機腳本：換成更長的新檔(錨點不同)送 replaced,不把新檔接在舊游標後面")
    func scriptReportsLongerReplacement() async throws {
        let follow = try await Self.localFollow()
        var events = follow.events.makeAsyncIterator()
        try follow.host.append(Self.line(Self.secondLine), to: Self.relativePath)
        follow.pace.wake()
        _ = try await events.next()

        try follow.host.write(Self.line(#"{"m":1}"#) + Self.line(#"{"m":2}"#) + Self.line(#"{"m":3}"#), to: Self.relativePath)
        try Self.touchLater(follow.url)
        follow.pace.wake()

        #expect(try await events.next() == .replaced(size: 24))
    }

    /// 測試在指令後面多帶一個獨特參數，事後以 `ps` 確認沒有任何程序還帶著它。
    /// `sendsRequests` 時由 shell 每 0.5 秒送一個請求(不靠測試程序的排程;腳本結束後寫入失敗，迴圈跟著結束)。
    static func run(follow command: String, sendsRequests: Bool = false) async throws -> (output: CollectedOutput, elapsed: Duration, leftover: [String]) {
        let marker = "purrdr-test-\(UUID().uuidString)"
        let host = try LocalShellHost.temporary(feedsStdin: !sendsRequests)
        let requests = #"(while printf '%s\n' '0 - - /nonexistent/a.jsonl'; do sleep 0.5; done) | "#
        let started = ContinuousClock.now
        let session = try await host.execute((sendsRequests ? requests : "") + command + " " + marker)
        let output = try await session.collectOutput()
        let elapsed = ContinuousClock.now - started
        try await Task.sleep(for: .seconds(2))
        return (output, elapsed, processes(containing: marker))
    }

    static func processes(containing marker: String) -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return listing.split(separator: "\n").map(String.init).filter { $0.contains(marker) }
    }

    @Test("主機腳本：閒置時限到了以 exit 124 結束，不留下程序")
    func scriptIdleLimit() async throws {
        let result = try await Self.run(follow: TranscriptCommand.follow(idleSeconds: 2, totalSeconds: 60))

        #expect(result.output.exitCode == 124, "stderr: \(String(decoding: result.output.stderr, as: UTF8.self))")
        #expect(result.elapsed < .seconds(20))
        #expect(result.leftover.isEmpty, "\(result.leftover)")
    }

    @Test("主機腳本：一直有請求也在總長時限到了以 exit 124 結束，不留下程序")
    func scriptTotalLimit() async throws {
        let result = try await Self.run(follow: TranscriptCommand.follow(idleSeconds: 3, totalSeconds: 5), sendsRequests: true)

        #expect(result.output.exitCode == 124, "stderr: \(String(decoding: result.output.stderr, as: UTF8.self))")
        #expect(result.elapsed >= .seconds(4))
        #expect(result.elapsed < .seconds(25))
        #expect(result.output.stdoutText.contains("error 3\n"), "請求照常回應")
        #expect(result.leftover.isEmpty, "\(result.leftover)")
    }
    #endif
}
