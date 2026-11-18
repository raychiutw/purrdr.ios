import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 對話紀錄的讀取靠主機上的 POSIX 腳本。這裡用 `LocalShellHost` 在本機 `/bin/sh` 對真實檔案跑同一份腳本
/// (家目錄是暫存資料夾),內容是從真實 Claude Code 對話紀錄擷取的 fixture。
@Suite("對話紀錄讀取(主機腳本)")
struct TranscriptReaderTests {
    static let sessionID = "0000c1a0-0000-4000-8000-000000000001"
    static let cwd = "/Users/demo/Projects/ledger"
    static let relativePath = ".claude/projects/-Users-demo-Projects-ledger/\(sessionID).jsonl"
    static let fixture = Fixtures.transcript()
    static let fixtureLines = Fixtures.transcriptLines()

    static func host(with data: Data = fixture) throws -> (LocalShellHost, String) {
        let host = try LocalShellHost.temporary()
        let url = try host.write(data, to: relativePath)
        return (host, url.path(percentEncoded: false))
    }

    @Test("定位：依 cwd 轉成的資料夾找到 <session id>.jsonl,回報路徑與 byte 大小")
    func locateFindsTranscriptByProjectFolder() async throws {
        let (host, path) = try Self.host()

        let file = try await TranscriptReader(channel: host).locate(sessionID: Self.sessionID, cwd: Self.cwd)

        #expect(file == TranscriptFile(path: path, size: Self.fixture.count))
    }

    /// R-I11、#89:預期位置不存在時(worktree),在所有專案資料夾找**完全相同檔名**,只會命中回報的那個 id。
    @Test("定位：預期資料夾沒有時，在其他專案資料夾找完全相同的檔名")
    func locateFallsBackToExactFileNameInOtherFolders() async throws {
        let host = try LocalShellHost.temporary()
        let url = try host.write(Self.fixture, to: ".claude/projects/-Users-demo-Projects-ledger-worktree/\(Self.sessionID).jsonl")
        try host.write(Self.fixture, to: ".claude/projects/-Users-demo-Projects-ledger/ffffffff-0000-4000-8000-000000000009.jsonl")

        let file = try await TranscriptReader(channel: host).locate(sessionID: Self.sessionID, cwd: Self.cwd)

        #expect(file.path == url.path(percentEncoded: false))
    }

    /// R-I09、R-I10:新 session 在第一個 prompt 前可能還沒有檔案——這是「缺席」,不是錯誤。
    @Test("定位：檔案還不存在是缺席(absent)")
    func locateReportsAbsentTranscript() async throws {
        let host = try LocalShellHost.temporary()

        await #expect(throws: TranscriptReadError.absent) {
            try await TranscriptReader(channel: host).locate(sessionID: Self.sessionID, cwd: Self.cwd)
        }
    }

    /// R-I10:只有「檔案／資料夾不存在」是缺席;權限錯誤要回報，否則對話永遠在等(#23、#46)。
    @Test("定位：檔案不可讀是錯誤，不是缺席")
    func locateReportsUnreadableTranscript() async throws {
        let (host, path) = try Self.host()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

        await #expect(throws: TranscriptReadError.unreadable) {
            try await TranscriptReader(channel: host).locate(sessionID: Self.sessionID, cwd: Self.cwd)
        }
    }

    @Test("Session id 不安全時不執行任何指令")
    func unsafeSessionIDIsRejectedBeforeShell() async throws {
        let host = FakeHost()

        await #expect(throws: TranscriptReadError.invalidReference) {
            try await TranscriptReader(channel: host).locate(sessionID: "x; rm -rf ~", cwd: Self.cwd)
        }
        #expect(await host.executions.isEmpty)
    }

    /// R-B04:開啟讀最後 N 行(以行計，不以 byte 計)。
    @Test("視窗：讀最後 N 行，回報視窗的 byte 起點與終點")
    func windowReadsLastLines() async throws {
        let (host, path) = try Self.host()

        let chunk = try await TranscriptReader(channel: host).window(path: path, endingAt: Self.fixture.count, lines: 3)

        let lastThree = Array(Self.fixtureLines.suffix(3))
        #expect(chunk.lines == lastThree)
        #expect(chunk.end == Self.fixture.count)
        #expect(chunk.start == Self.fixture.count - lastThree.reduce(0) { $0 + $1.utf8.count + 1 })
    }

    @Test("視窗：正在寫的未完成行留給追蹤，不算在視窗裡")
    func windowExcludesUnfinishedLine() async throws {
        let unfinished = Data(Self.fixtureLines[6].utf8.prefix(50))
        let (host, path) = try Self.host(with: Self.fixture + unfinished)

        let chunk = try await TranscriptReader(channel: host).window(path: path, endingAt: Self.fixture.count + unfinished.count, lines: 2)

        #expect(chunk.lines == Array(Self.fixtureLines.suffix(2)))
        #expect(chunk.end == Self.fixture.count)
    }

    @Test("視窗：區塊不夠 N 行時放大區塊重數，直到檔頭")
    func windowGrowsChunkUntilEnoughLines() async throws {
        let (host, path) = try Self.host()

        let chunk = try await TranscriptReader(channel: host, windowChunkBytes: 64).window(path: path, endingAt: Self.fixture.count, lines: 300)

        #expect(chunk.start == 0)
        #expect(chunk.lines == Self.fixtureLines)
    }

    /// R-B04:Claude 把讀過的圖片以 base64 內嵌，單行可達 1MB。主機上把圖片資料換成空字串，
    /// 但被剝除的行仍是一行，byte 位置照原檔計。
    @Test("視窗：主機上剝除圖片 base64,byte 位置仍以原檔計")
    func windowStripsImageDataOnHost() async throws {
        let base64 = String(repeating: "iVBORw0KGgo", count: 40)
        let imageLine = Fixtures.transcriptLine(6) {
            $0["message"] = ["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": base64]],
                ["type": "text", "text": "看這張圖 data:image/png;base64,AAAA"],
            ]]
        }
        let data = Self.fixture + Data((imageLine + "\n").utf8)
        let (host, path) = try Self.host(with: data)

        let chunk = try await TranscriptReader(channel: host).window(path: path, endingAt: data.count, lines: 1)

        #expect(chunk.end == data.count)
        #expect(chunk.start == Self.fixture.count)
        #expect(chunk.lines.first?.contains(base64) == false)
        #expect(chunk.lines.first?.contains(#""data":"""#) == true)
        #expect(chunk.lines.first?.contains("看這張圖") == true)
    }

    /// R-B01、R-B02:游標是檔案的 UTF-8 byte 數，絕不用 UTF-16 長度(含 emoji 與中文時會漂移，默默跳過訊息)。
    @Test("追蹤：從游標讀新增的完整行，游標以 UTF-8 byte 推進(中文與 emoji)")
    func tailReadsAppendedLinesByUTF8Bytes() async throws {
        let (host, path) = try Self.host()
        let added = [Self.fixtureLines[6], Self.fixtureLines[18]]
        try host.append(Data((added.joined(separator: "\n") + "\n").utf8), to: Self.relativePath)

        let tail = try await TranscriptReader(channel: host).tail(path: path, from: Self.fixture.count)

        let addedBytes = added.reduce(0) { $0 + $1.utf8.count + 1 }
        #expect(addedBytes != added.reduce(0) { $0 + $1.utf16.count + 1 })
        #expect(tail == .appended(TranscriptChunk(start: Self.fixture.count, end: Self.fixture.count + addedBytes, lines: added)))
    }

    @Test("追蹤：檔案沒變時不回傳任何行")
    func tailReportsUnchanged() async throws {
        let (host, path) = try Self.host()

        let tail = try await TranscriptReader(channel: host).tail(path: path, from: Self.fixture.count)

        #expect(tail == .unchanged)
    }

    @Test("追蹤：尾端未完成的行不消化，游標停在最後一個換行之後")
    func tailLeavesUnfinishedLine() async throws {
        let (host, path) = try Self.host()
        let line = Self.fixtureLines[6]
        try host.append(Data((line + "\n" + "{\"type\":\"user\",\"mess").utf8), to: Self.relativePath)

        let tail = try await TranscriptReader(channel: host).tail(path: path, from: Self.fixture.count)

        #expect(tail == .appended(TranscriptChunk(start: Self.fixture.count, end: Self.fixture.count + line.utf8.count + 1, lines: [line])))
    }

    /// R-B08:落後超過上限時不從游標逐行補(11MB 的落差花了好幾分鐘,#66),改讀新視窗。
    @Test("追蹤：落後超過上限時回報 tooFarBehind,不傳內容")
    func tailRefusesLargeBacklog() async throws {
        let (host, path) = try Self.host()

        let tail = try await TranscriptReader(channel: host).tail(path: path, from: 0, limit: 1024)

        #expect(tail == .tooFarBehind(size: Self.fixture.count))
    }

    /// #130:畫面已有內容的即時追蹤落後超過上限時，從游標分段接著讀(不改讀新視窗取代畫面)。
    @Test("分段追趕：落後超過上限時，從游標讀不超過上限的完整行，其餘留給下一次")
    func catchUpReadsCompleteLinesUpToLimit() async throws {
        let (host, path) = try Self.host()
        let reader = TranscriptReader(channel: host)
        let lines = Self.fixtureLines
        let limit = lines[0].utf8.count + 1 + lines[1].utf8.count + 1 + lines[2].utf8.count / 2

        let first = try await reader.catchUp(path: path, from: 0, limit: limit)

        let twoLines = lines[0].utf8.count + 1 + lines[1].utf8.count + 1
        #expect(first == .appended(TranscriptChunk(start: 0, end: twoLines, lines: Array(lines[0...1]))))

        // 接著讀到檔尾，最後與整份檔案相同。
        var cursor = twoLines
        var collected = Array(lines[0...1])
        while case .appended(let chunk) = try await reader.catchUp(path: path, from: cursor, limit: max(limit, 64 << 10)) {
            #expect(chunk.start == cursor)
            collected += chunk.lines
            cursor = chunk.end
        }
        #expect(cursor == Self.fixture.count)
        #expect(collected.count == lines.count)
    }

    /// 不能分段接著讀的連線方式(HTTPS 主機服務的追蹤落後超過上限就結束、只回大小):一行都沒拿到卻落後超過上限時
    /// 回報落後太多，讓呼叫端讀新視窗，不卡在同一個游標(合併 #109 與 #130)。只回大小、落後在上限內(還在寫的半行)照舊是沒有變化。
    @Test("分段追趕：一行都沒拿到卻落後超過上限時回報落後太多;落後在上限內照舊沒有變化")
    func catchUpWithoutLinesBeyondLimitReportsTooFarBehind() async throws {
        let path = "/Users/demo/.claude/projects/-Users-demo-ledger/session.jsonl"
        let host = FakeHost()
        await host.expect(TranscriptCommand.catchUp(path: path, from: 100, limit: 1024), reply: FakeReply(stdout: Data("5000\n".utf8)))
        await host.expect(TranscriptCommand.catchUp(path: path, from: 100, limit: 8192), reply: FakeReply(stdout: Data("5000\n".utf8)))
        let reader = TranscriptReader(channel: host)

        #expect(try await reader.catchUp(path: path, from: 100, limit: 1024) == .tooFarBehind(size: 5000))
        #expect(try await reader.catchUp(path: path, from: 100, limit: 8192) == .unchanged)
    }

    /// 單行比上限大(大的工具結果):以完整行前進，不卡在同一個游標(#130 review 5)。剝除圖片後仍超過上限的行
    /// 在主機端截短到上限(傳輸量與期限都以上限為準),游標照原始長度前進;截短的行解析不出來，畫面略過。
    @Test("分段追趕：第一行就超過上限時截短到上限，游標照原始長度前進，下一次讀下一行")
    func catchUpTruncatesOversizedLine() async throws {
        let big = #"{"type":"assistant","text":""# + String(repeating: "long output ", count: 400) + #""}"#
        let next = Self.fixtureLines[6]
        let (host, path) = try Self.host(with: Data((big + "\n" + next + "\n").utf8))
        let reader = TranscriptReader(channel: host)

        guard case .appended(let chunk) = try await reader.catchUp(path: path, from: 0, limit: 1024) else {
            Issue.record("應該讀到截短的第一行")
            return
        }

        #expect(big.utf8.count > 1024)
        #expect(chunk.start == 0 && chunk.end == big.utf8.count + 1)
        #expect(chunk.lines.count == 1)
        #expect(chunk.lines[0].utf8.count == 1024)
        #expect(big.utf8.starts(with: chunk.lines[0].utf8))
        #expect(try await reader.catchUp(path: path, from: chunk.end, limit: 1024) == .appended(TranscriptChunk(start: chunk.end, end: big.utf8.count + 1 + next.utf8.count + 1, lines: [next])))
    }

    /// 以 fixture 第 6 行(使用者打的字)為底，換掉 uuid 與內容的大行(約 `bytes` bytes)。
    static func bigLine(_ index: Int, bytes: Int) -> String {
        fixtureLines[6]
            .replacingOccurrences(of: "00000000-0000-4000-8000-000000000008", with: String(format: "00000000-0000-4000-8000-0000000c%04x", index))
            .replacingOccurrences(of: "幫我把 CSV 匯出整理一下 🧾", with: String(repeating: "word ", count: bytes / 5))
    }

    /// #130 review 1、3、10:即時追蹤的讀法。還沒追上(剛開啟或重新可見)時落後超過 64 KiB 不逐段重播(R-B08);
    /// 追上之後落後多少都從游標分段接著讀，落後很多時下一次讀大一點(1 MiB),一個指令就追得上高速輸出。
    @Test("追蹤：還沒追上時落後太多回報 tooFarBehind;追上之後分段接著讀，落後很多時下一次讀 1 MiB")
    func followReadsInGrowingSegmentsOnceLive() async throws {
        let lines = (1...150).map { Self.bigLine($0, bytes: 10_000) }
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        let (host, path) = try Self.host(with: data)
        let reader = TranscriptReader(channel: host)

        let reopened = try await reader.follow(path: path, TranscriptFollow(cursor: 0, isLive: false))
        #expect(reopened.tail == .tooFarBehind(size: data.count))

        let first = try await reader.follow(path: path, TranscriptFollow(cursor: 0, isLive: true))
        guard case .appended(let chunk) = first.tail else {
            Issue.record("應該讀到第一段")
            return
        }
        #expect(chunk.end <= 256 << 10)
        #expect(first.next.cursor == chunk.end && first.next.isLive)
        #expect(first.next.limit == 1 << 20)

        let second = try await reader.follow(path: path, first.next)
        guard case .appended(let more) = second.tail else {
            Issue.record("應該讀到第二段")
            return
        }
        #expect(more.end - more.start > 256 << 10 && more.end - more.start <= 1 << 20)
        #expect(second.next.cursor == more.end)
    }

    /// #130 review 10:還沒追上時，檔案長大但只有未完成的行不算追上(之後落後太多仍讀新視窗);游標等於大小才算。
    @Test("追蹤：還沒追上時只有未完成的行不算追上，游標等於檔案大小才算")
    func followBecomesLiveOnlyWhenCaughtUp() async throws {
        let (host, path) = try Self.host()
        let reader = TranscriptReader(channel: host)

        let idle = try await reader.follow(path: path, TranscriptFollow(cursor: Self.fixture.count, isLive: false))
        #expect(idle.tail == .unchanged && idle.next.isLive)

        try host.append(Data(#"{"type":"user","mess"#.utf8), to: Self.relativePath)
        let partial = try await reader.follow(path: path, TranscriptFollow(cursor: Self.fixture.count, isLive: false))
        #expect(partial.tail == .unchanged && !partial.next.isLive)

        var live = idle.next
        live.reopen()
        #expect(!live.isLive && live.limit == 256 << 10)
    }

    @Test("分段追趕：沒有新的完整行是 unchanged,檔案變小是 shrank")
    func catchUpReportsUnchangedAndShrunk() async throws {
        let (host, path) = try Self.host()
        let reader = TranscriptReader(channel: host)
        try host.append(Data(#"{"type":"user","mess"#.utf8), to: Self.relativePath)

        #expect(try await reader.catchUp(path: path, from: Self.fixture.count, limit: 1024) == .unchanged)
        #expect(try await reader.catchUp(path: path, from: Self.fixture.count + 1000, limit: 1024) == .shrank(size: Self.fixture.count + 20))
    }

    @Test("追蹤：檔案比游標短(被換掉)時回報 shrank")
    func tailReportsShrunkFile() async throws {
        let (host, path) = try Self.host()

        let tail = try await TranscriptReader(channel: host).tail(path: path, from: Self.fixture.count + 10)

        #expect(tail == .shrank(size: Self.fixture.count))
    }

    /// 往上翻舊歷史(F5.4):同樣的視窗讀取,`end = 目前視窗起點`;起點 0 即到頂。
    @Test("往上翻：以目前視窗起點為終點讀上一頁，直到 byte 0")
    func olderPagesReachTheStart() async throws {
        let (host, path) = try Self.host()
        let reader = TranscriptReader(channel: host)

        var chunk = try await reader.window(path: path, endingAt: Self.fixture.count, lines: 7)
        var collected = chunk.lines
        while chunk.start > 0 {
            chunk = try await reader.window(path: path, endingAt: chunk.start, lines: 7)
            collected = chunk.lines + collected
        }

        #expect(collected == Self.fixtureLines)
    }
}

@Suite("列表預覽(主機腳本)")
struct TranscriptPreviewTests {
    /// 行為規格 §4.7、R-L01:所有聊天的預覽合成一次往返;每個請求以「隨機分隔標記 + key」分段
    /// (固定標記曾被對話內容撞到);一個檔不存在不讓整批失敗。
    @Test("一次往返讀所有聊天的檔尾，依 key 回傳預覽;沒有檔案的沒有預覽")
    func previewsAreBatchedInOneCommand() async throws {
        let host = try LocalShellHost.temporary()
        try host.write(Fixtures.transcript(), to: ".claude/projects/-Users-demo-Projects-ledger/\(TranscriptReaderTests.sessionID).jsonl")
        let recorder = RoutingHost(shell: host)
        let reader = TranscriptReader(channel: recorder, marker: { "MARK-1234" })

        let previews = try await reader.previews(of: [
            PreviewRequest(key: "w1:p1", sessionID: TranscriptReaderTests.sessionID, cwd: "/Users/demo/Projects/ledger"),
            PreviewRequest(key: "w2:p1", sessionID: "00000000-0000-4000-8000-0000000000ff", cwd: "/Users/demo/Projects/ledger"),
        ])

        #expect(await recorder.shellCommands.count == 1)
        #expect(previews.keys.sorted() == ["w1:p1"])
        #expect(previews["w1:p1"]?.text.hasPrefix("CSV 匯出整理好了 ✅") == true)
        #expect(previews["w1:p1"]?.isFromUser == false)
    }

    @Test("Session id 不安全的請求直接略過，不進 shell")
    func unsafePreviewRequestsAreSkipped() async throws {
        let host = FakeHost()
        let previews = try await TranscriptReader(channel: host).previews(of: [
            PreviewRequest(key: "w1:p1", sessionID: "$(reboot)", cwd: "/Users/demo"),
        ])
        #expect(previews.isEmpty)
        #expect(await host.executions.isEmpty)
    }
}
