import Foundation
@testable import PurrdrCore
@testable import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 一次性主機指令一律有期限(#91、spec #86):主機上的指令卡住(不結束、也不輸出)時，期限到就關閉通道並丟
/// `HostCommandError.deadlineExceeded`;外層取消立刻返回並關閉通道。卡住以假主機「回應後保持開著」模擬。
@Suite("主機指令期限")
struct HostCommandDeadlineTests {
    typealias Sleep = @Sendable (Duration) async throws -> Void

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
            _ = try await TranscriptReader(channel: host, marker: { "m" }, sleep: sleep).previews(of: previewRequests(2))
        },
        StuckCommand(
            testDescription: "讀對話紀錄：列表預覽(100 個聊天，封頂 100 秒)",
            command: TranscriptCommand.previews(marker: "m", entries: previewRequests(100).compactMap(TranscriptCommand.PreviewEntry.init)),
            deadline: .seconds(100)
        ) { host, sleep in
            _ = try await TranscriptReader(channel: host, marker: { "m" }, sleep: sleep).previews(of: previewRequests(100))
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
            command: HerdrCommand.pluginList(id: PushHost.pluginID, herdr: HerdrInstallation()),
            deadline: .seconds(20)
        ) { host, sleep in
            let push = PushHost(channel: host, herdr: HerdrInstallation(), deviceID: "0123456789abcdef", pluginSource: "owner/repo", sleep: sleep)
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

        let outcome = await Self.outcome { try await stuck.run(host, sleeper.sleep) }

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

        let finished = await Self.outcome { try await task.value }
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

        let finished = await Self.outcome { try await task.value }
        await channel.open()
        #expect(finished != nil, "開通道卡住時，取消後沒有立刻返回")
        #expect(await host.waitUntilClosed(execution: 0))
    }

    // MARK: - 輔助

    /// 在 `limit` 內等 `operation` 結束;沒結束就取消它並回傳 `nil`(卡住時以斷言失敗呈現，不讓測試掛住)。
    /// 上限放寬到 `asyncWaitLimit`:平行跑的其他測試會以同步等待佔住執行緒。
    static func outcome<Value: Sendable>(
        within limit: Duration = asyncWaitLimit, _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, any Error>? {
        let box = OutcomeBox<Value>()
        let task = Task {
            do {
                await box.set(.success(try await operation()))
            } catch {
                await box.set(.failure(error))
            }
        }
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let result = await box.result { return result }
            try? await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        return nil
    }
}

private actor OutcomeBox<Value: Sendable> {
    var result: Result<Value, any Error>?
    func set(_ result: Result<Value, any Error>) { self.result = result }
}

/// 開通道時先卡在一個不理會取消的閘門，`open()` 之後才交給底層通道。
private actor GatedChannel: HostChannel {
    let base: any HostChannel
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    init(base: any HostChannel) {
        self.base = base
    }

    func execute(_ command: String) async throws -> any ExecSession {
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        return try await base.execute(command)
    }

    func openPTY(_ request: PTYRequest) async throws -> any PTYSession { try await base.openPTY(request) }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func waitUntilWaiting(timeout: Duration = asyncWaitLimit) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while waiting.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return !waiting.isEmpty
    }
}
