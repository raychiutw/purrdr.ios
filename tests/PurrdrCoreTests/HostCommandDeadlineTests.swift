import Foundation
@testable import PurrdrCore
@testable import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 一次性主機指令一律有期限(#91、spec #86):主機上的指令卡住(不結束、也不輸出)時，期限到就關閉通道並丟
/// `HostCommandError.deadlineExceeded`;外層取消立刻返回並關閉通道。卡住以假主機「回應後保持開著」模擬。
@Suite("主機指令期限")
struct HostCommandDeadlineTests {
    /// 一種一次性主機指令：卡住的指令字串、預期的期限，以及經正式程式路徑送出它的動作。
    struct StuckCommand: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let command: String
        let deadline: Duration
        let run: @Sendable (FakeHost, @escaping Sleep) async throws -> Void
    }

    static let sessionID = "00000000-0000-0000-0000-000000000001"
    static let cwd = "/Users/demo/Projects/garden-journal"
    static let transcriptPath = "/Users/demo/.claude/projects/-Users-demo-Projects-garden-journal/\(sessionID).jsonl"

    static let stuckCommands: [StuckCommand] = [
        StuckCommand(
            testDescription: "讀對話紀錄：定位",
            command: TranscriptCommand.locate(sessionID: sessionID, projectFolder: ClaudeTranscript.projectFolder(forCWD: cwd)),
            deadline: .seconds(20)
        ) { host, sleep in
            _ = try await TranscriptReader(channel: host, sleep: sleep).locate(sessionID: sessionID, cwd: cwd)
        },
        StuckCommand(
            testDescription: "讀對話紀錄：追蹤(20 秒加上 64 KiB 的傳輸時間)",
            command: TranscriptCommand.tail(path: transcriptPath, from: 100, limit: 64 << 10),
            deadline: .milliseconds(22_048)
        ) { host, sleep in
            _ = try await TranscriptReader(channel: host, sleep: sleep).tail(path: transcriptPath, from: 100)
        },
        // #130:超大單行在主機端截短，傳輸量不超過這次的上限，期限依上限估算(一般的小增量不給大段讀取的期限)。
        StuckCommand(
            testDescription: "讀對話紀錄：分段追趕(20 秒加上 256 KiB 的傳輸時間)",
            command: TranscriptCommand.catchUp(path: transcriptPath, from: 100, limit: 256 << 10),
            deadline: .milliseconds(28_192)
        ) { host, sleep in
            _ = try await TranscriptReader(channel: host, sleep: sleep).catchUp(path: transcriptPath, from: 100)
        },
        StuckCommand(
            testDescription: "讀對話紀錄：分段追趕、落後很多時的大段讀取(20 秒加上 1 MiB 的傳輸時間)",
            command: TranscriptCommand.catchUp(path: transcriptPath, from: 100, limit: 1 << 20),
            deadline: .milliseconds(52_768)
        ) { host, sleep in
            _ = try await TranscriptReader(channel: host, sleep: sleep).catchUp(path: transcriptPath, from: 100, limit: 1 << 20)
        },
        StuckCommand(
            testDescription: "讀對話紀錄：視窗(4 MiB 區塊估算要 151 秒，封頂 100 秒，比主機腳本的自我時限 120 秒短)",
            command: TranscriptCommand.window(path: transcriptPath, end: 5000, lines: 200, chunkBytes: 4 << 20),
            deadline: .seconds(100)
        ) { host, sleep in
            _ = try await TranscriptReader(channel: host, sleep: sleep).window(path: transcriptPath, endingAt: 5000, lines: 200)
        },
        StuckCommand(
            testDescription: "讀對話紀錄：列表預覽(2 個聊天，20 秒加上 2 × 48,000 bytes 的傳輸時間)",
            command: TranscriptCommand.previews(marker: "m", entries: previewRequests(2).compactMap(TranscriptCommand.PreviewEntry.init)),
            deadline: .milliseconds(23_000)
        ) { host, sleep in
            _ = try await TranscriptReader(channel: host, marker: { "m" }, sleep: sleep).previewReadings(of: previewRequests(2))
        },
        StuckCommand(
            testDescription: "讀對話紀錄：列表預覽(100 個聊天，封頂 100 秒)",
            command: TranscriptCommand.previews(marker: "m", entries: previewRequests(100).compactMap(TranscriptCommand.PreviewEntry.init)),
            deadline: .seconds(100)
        ) { host, sleep in
            _ = try await TranscriptReader(channel: host, marker: { "m" }, sleep: sleep).previewReadings(of: previewRequests(100))
        },
        StuckCommand(
            testDescription: "新增對話的資料夾清單",
            command: NewChatFolders.command(for: "~/Projects"),
            deadline: .seconds(20)
        ) { host, sleep in
            _ = try await NewChatFolders(channel: host, sleep: sleep).list("~/Projects")
        },
        StuckCommand(
            testDescription: "資料夾瀏覽",
            command: HostFolderCommand.list("/Users/demo"),
            deadline: .seconds(20)
        ) { host, sleep in
            _ = try await HostFolders(channel: host, sleep: sleep).list("/Users/demo")
        },
        StuckCommand(
            testDescription: "主機檔案讀取",
            command: HostFileScript.command(HostFileScript.read, arguments: [".purrdr/theme/README.md"]),
            deadline: .seconds(20)
        ) { host, sleep in
            _ = try await HostFiles(channel: host, sleep: sleep).read([HostPath(".purrdr/theme/README.md")])
        },
        StuckCommand(
            testDescription: "推播外掛：檢查是否已安裝",
            command: HerdrCommand.pluginList(id: SSHPushPluginInstaller.pluginID, herdr: HerdrInstallation()),
            deadline: .seconds(20)
        ) { host, sleep in
            let push = SSHPushPluginInstaller(channel: host, herdr: HerdrInstallation(), deviceID: PushDeviceID(rawValue: "0123456789abcdef")!, pluginSource: "owner/repo", sleep: sleep)
            _ = try await push.pluginInstalled()
        },
        StuckCommand(
            testDescription: "偵測主機作業系統(探測，期限較短)",
            command: HerdrCommand.operatingSystem,
            deadline: .seconds(10)
        ) { host, sleep in
            _ = try await HostOperatingSystem.detect(on: host, sleep: sleep)
        },
    ]

    static func previewRequests(_ count: Int) -> [PreviewRequest] {
        (0..<count).map { PreviewRequest(key: "chat\($0)", sessionID: sessionID, cwd: cwd) }
    }

    /// 主機腳本的自我時限(#92)到了以 exit 124 結束：同樣是逾時，不是一般失敗或缺席。
    @Test("主機腳本自己逾時(exit 124):當成逾時", arguments: stuckCommands)
    func hostScriptTimeLimitIsDeadline(_ stuck: StuckCommand) async throws {
        let host = FakeHost()
        await host.expect(stuck.command, reply: FakeReply(exitCode: 124))
        let sleeper = RecordingSleeper()

        await #expect(throws: HostCommandError.deadlineExceeded) { try await stuck.run(host, sleeper.sleep) }
    }

    @Test("上傳時主機腳本自己逾時(exit 124):圖片與檔案上傳都當成逾時")
    func uploadTimeLimitIsDeadline() async throws {
        let host = FakeHost()
        let data = Data("hello".utf8)
        let name = try #require(UploadFileName("a.png"))
        await host.expect(ImageUploadCommand.posix(name: name, size: data.count), reply: FakeReply(exitCode: 124))
        await host.expect(
            HostFolderCommand.upload(FolderUpload(folder: "/Users/demo", name: "a.txt", originalSize: data.count, encoding: .identity, transferSize: data.count)),
            reply: FakeReply(exitCode: 124))

        await #expect(throws: ImageUploadError.deadlineExceeded) { _ = try await ImageUploader(channel: host).upload(data, named: name) }
        await #expect(throws: HostFolderError.deadlineExceeded) { _ = try await HostFolders(channel: host).upload(data, named: "a.txt", to: "/Users/demo") }
    }

    @Test("指令卡住：期限到時丟逾時錯誤並關閉通道", arguments: stuckCommands)
    func stuckCommandTimesOut(_ stuck: StuckCommand) async throws {
        let host = FakeHost()
        await host.expect(stuck.command, reply: FakeReply(keepsOpen: true))
        let sleeper = RecordingSleeper { $0 == stuck.deadline }

        let outcome = await boundedOutcome { try await stuck.run(host, sleeper.sleep) }

        guard let outcome else {
            Issue.record("指令卡住後沒有在期限到時返回(期限 \(stuck.deadline);要求過的等待：\(await sleeper.requested))")
            return
        }
        #expect(throws: HostCommandError.deadlineExceeded) { try outcome.get() }
        #expect(await host.waitUntilClosed(execution: 0))
        #expect(await sleeper.requested.contains(stuck.deadline))
    }

    @Test("外層取消：卡住等輸出的指令立刻返回並關閉通道")
    func cancellationReturnsWhileWaitingForOutput() async throws {
        let host = FakeHost()
        let stuck = Self.stuckCommands[0]
        await host.expect(stuck.command, reply: FakeReply(keepsOpen: true))
        let sleeper = RecordingSleeper()
        let task = Task { try await stuck.run(host, sleeper.sleep) }
        #expect(await host.waitForExecutions(1) == 1)

        task.cancel()

        let finished = await boundedOutcome { try await task.value }
        #expect(finished != nil, "取消後沒有立刻返回")
        #expect(await host.waitUntilClosed(execution: 0))
    }

    /// 開通道這一步不理會取消時(例如 NIO 的 future、Windows 送 stdin 腳本)，外層取消也要立刻返回;
    /// 通道晚到時一到就關閉。
    @Test("外層取消：開通道卡住也立刻返回，晚到的通道一到就關閉")
    func cancellationReturnsWhileOpeningChannel() async throws {
        let host = FakeHost()
        let stuck = Self.stuckCommands[0]
        await host.expect(stuck.command, reply: FakeReply(keepsOpen: true))
        let channel = GatedChannel(base: host)
        let sleeper = RecordingSleeper()
        let task = Task {
            _ = try await TranscriptReader(channel: channel, sleep: sleeper.sleep).locate(sessionID: Self.sessionID, cwd: Self.cwd)
        }
        #expect(await channel.waitUntilWaiting())

        task.cancel()

        let finished = await boundedOutcome { try await task.value }
        await channel.open()
        #expect(finished != nil, "開通道卡住時，取消後沒有立刻返回")
        #expect(await host.waitUntilClosed(execution: 0))
    }

    /// 開通道卡住時要立刻回應外層取消的操作：上傳與 herdr 請求原本各自計時，現在都經同一個入口(#86)。
    struct OpeningOperation: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let command: String
        let run: @Sendable (any HostChannel) async throws -> Void
    }

    static let openingOperations: [OpeningOperation] = [
        OpeningOperation(
            testDescription: "圖片上傳",
            command: ImageUploadCommand.posix(name: UploadFileName("a.png")!, size: 5)
        ) { channel in
            _ = try await ImageUploader(channel: channel, sleep: RecordingSleeper().sleep).upload(Data("hello".utf8), named: UploadFileName("a.png")!)
        },
        OpeningOperation(
            testDescription: "檔案上傳",
            command: HostFolderCommand.upload(folder: "/Users/demo", name: "a.txt", size: 5)
        ) { channel in
            _ = try await HostFolders(channel: channel, sleep: RecordingSleeper().sleep).upload(Data("hello".utf8), named: "a.txt", to: "/Users/demo")
        },
        OpeningOperation(testDescription: "herdr 單次請求", command: HerdrCommand.bridge()) { channel in
            _ = try await HerdrClient(channel: channel, sleep: RecordingSleeper().sleep).snapshot()
        },
    ]

    @Test("外層取消：上傳與 herdr 請求在開通道卡住時也立刻返回，晚到的通道一到就關閉", arguments: openingOperations)
    func cancellationReturnsWhileOpeningChannelForEveryEntry(_ operation: OpeningOperation) async throws {
        let host = FakeHost()
        await host.expect(operation.command, reply: FakeReply(keepsOpen: true))
        let channel = GatedChannel(base: host)
        let task = Task { try await operation.run(channel) }
        #expect(await channel.waitUntilWaiting())

        task.cancel()

        let finished = await boundedOutcome { try await task.value }
        await channel.open()
        #expect(finished != nil, "開通道卡住時，取消後沒有立刻返回")
        #expect(await host.waitUntilClosed(execution: 0))
    }

    /// 掛起期間死掉的連線，開通道本身就可能卡住：喚醒探測的 3 秒包含開通道。
    @Test("喚醒探測：開通道卡住時 3 秒到就回報失敗並丟棄連線")
    func wakeProbeGivesUpWhileOpeningChannel() async throws {
        let host = FakeHost()
        await host.expect(WakeProbe.command, reply: FakeReply(keepsOpen: true))
        let channel = GatedChannel(base: host)
        let sleeper = RecordingSleeper { $0 == WakeProbe.timeout }

        let outcome = await boundedOutcome { await WakeProbe(channel: channel, sleep: sleeper.sleep).run() }
        await channel.open()

        guard let outcome else {
            Issue.record("開通道卡住時，喚醒探測沒有在 3 秒期限到時返回")
            return
        }
        #expect(try outcome.get() == false)
        #expect(await host.disconnectCount == 1)
        #expect(await host.waitUntilClosed(execution: 0))
    }
}
