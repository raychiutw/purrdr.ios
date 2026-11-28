import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 聊天裡圖片卡片的載入狀態(#225):畫面依 `AgentFileLoads.states` 顯示縮圖、「點擊載入」或原因。
@MainActor
@Suite("圖片卡片的載入狀態")
struct AgentFileLoadsTests {
    static let shot = "/Users/demo/ledger/shot.png"
    static let scope = HostFileAccessScope(workingDirectories: ["/Users/demo/ledger"], mentionedPaths: [])

    @Test("自動載入的縮圖：載入中 → 已載入;超過 8 MiB 顯示大小，點擊後載入")
    func loadingStates() async {
        let big = Data(count: HostFileFetchLimits.automaticLoad + 1)
        let fetcher = FakeHostFileFetcher(files: [Self.shot: Data("png".utf8), "/Users/demo/ledger/scan.png": big])
        let loads = AgentFileLoads(fetcher: fetcher)

        await loads.load(Self.shot, scope: Self.scope)
        guard case .loaded(let data, _) = loads.states[Self.shot] else { Issue.record("沒有載入"); return }
        #expect(data == Data("png".utf8))

        await loads.load("/Users/demo/ledger/scan.png", scope: Self.scope)
        #expect(loads.states["/Users/demo/ledger/scan.png"] == .overAutomaticLimit(size: big.count))
        await loads.load("/Users/demo/ledger/scan.png", scope: Self.scope, userRequested: true)
        guard case .loaded = loads.states["/Users/demo/ledger/scan.png"] else { Issue.record("點擊後沒有載入"); return }
    }

    @Test("缺檔、被拒、主機不支援各自成為狀態")
    func failureStates() async {
        let fetcher = FakeHostFileFetcher(files: [:])
        let loads = AgentFileLoads(fetcher: fetcher)

        await loads.load(Self.shot, scope: Self.scope)
        await loads.load("/Users/demo/.ssh/id_rsa", scope: HostFileAccessScope(workingDirectories: [], mentionedPaths: ["/Users/demo/.ssh/id_rsa"]))
        let unsupported = AgentFileLoads(fetcher: UnsupportedHostFileFetcher())
        await unsupported.load(Self.shot, scope: Self.scope)

        #expect(loads.states[Self.shot] == .missing)
        #expect(loads.states["/Users/demo/.ssh/id_rsa"] == .denied)
        #expect(unsupported.states[Self.shot] == .unsupported)
    }

    @Test("對話的存取範圍：Agent 的工作目錄、對話紀錄裡檔案卡片的路徑與目前的對話紀錄(Demo ledger 的檔案情境)")
    func conversationScope() async throws {
        let connection = SSHHostConnection(channel: DemoHost(scenario: .agentFiles))
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: "w1:p1",
            knownSessionID: nil, cache: InMemoryConversationCache())
        await model.poll()

        #expect(model.fileAccessScope.workingDirectories == ["/Users/demo/ledger"])
        #expect(model.fileAccessScope.mentionedPaths.isSuperset(of: [
            "/Users/demo/ledger/docs/export-preview.png", "/Users/demo/ledger/docs/statement-scan.png",
            "/Users/demo/ledger/Sources/Ledger/CSVExport.swift",
        ]))
        #expect(model.fileAccessScope.transcriptPaths.count == 1)
    }

    @Test("快取先還原時，存取範圍還沒有工作目錄;第一次輪詢後才有，卡片據此重載(#663 預讀造成的回歸)")
    func scopeAnchorAppearsAfterFirstPoll() async throws {
        let connection = SSHHostConnection(channel: DemoHost(scenario: .agentFiles))
        let cache = InMemoryConversationCache()
        let first = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: "w1:p1",
            knownSessionID: nil, cache: cache)
        await first.poll()
        #expect(first.hasFileAccessAnchor)
        await first.flushCache()

        let reopened = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: "w1:p1",
            knownSessionID: nil, cache: cache)
        await reopened.restoreFromCache()
        #expect(!reopened.items.isEmpty, "快取沒有還原")
        #expect(!reopened.hasFileAccessAnchor, "還原後、輪詢前沒有工作目錄，圖片卡片此時載入會被拒")
        #expect(reopened.fileAccessScope.workingDirectories.isEmpty)
        await reopened.poll()
        #expect(reopened.hasFileAccessAnchor)
    }

    @Test("已送出圖片情境：對話的存取範圍帶使用者 prompt 的上傳路徑，放行且標成使用者上傳(#428)")
    func sentImagesScope() async throws {
        let connection = SSHHostConnection(channel: DemoHost(scenario: .sentImages))
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: "w1:p1",
            knownSessionID: nil, cache: InMemoryConversationCache())
        await model.poll()

        let sent = DemoHostFileFetcher.sentImagePath
        #expect(model.fileAccessScope.promptMentionedPaths.isSuperset(of: [sent, DemoHostFileFetcher.clearedImagePath]))
        #expect(HostFileAccessPolicy.decision(for: sent, in: model.fileAccessScope) == .allowed(HostFileTarget(path: sent, root: nil, isUserUpload: true)))

        let loads = AgentFileLoads(fetcher: DemoHostFileFetcher())
        await loads.load(sent, scope: model.fileAccessScope)
        await loads.load(DemoHostFileFetcher.clearedImagePath, scope: model.fileAccessScope)
        guard case .loaded = loads.states[sent] else { Issue.record("沒有讀回縮圖"); return }
        #expect(loads.states[DemoHostFileFetcher.clearedImagePath] == .missing)
    }

    @Test("使用者上傳的圖片：版本沒變只查狀態、被清掉是缺檔、不在上傳資料夾的 prompt 路徑被拒(#428)")
    func userUploadLoading() async {
        let upload = "/var/folders/zz/demo/T/purrdr-uploads-501/a.png"
        let scope = HostFileAccessScope(workingDirectories: [], mentionedPaths: [], promptMentionedPaths: [upload, "/Users/demo/notes.txt"])
        let fetcher = FakeHostFileFetcher(files: [upload: Data("png".utf8)])
        let loads = AgentFileLoads(fetcher: fetcher)

        await loads.load(upload, scope: scope)
        await loads.load(upload, scope: scope)
        await loads.load("/Users/demo/notes.txt", scope: scope)

        guard case .loaded = loads.states[upload] else { Issue.record("沒有載入"); return }
        #expect(loads.states["/Users/demo/notes.txt"] == .denied)
        #expect(await fetcher.readCount == 1)
    }

    @Test("檔案卡片縮圖(#427):PDF 在 8 MiB 內自動載入、超過要點擊、超過 25 MiB 無法載入;版本沒變重看不重抓")
    func pdfThumbnailLoading() async {
        let report = "/Users/demo/ledger/report.pdf"
        let over = "/Users/demo/ledger/big.pdf"
        let huge = "/Users/demo/ledger/huge.pdf"
        let fetcher = FakeHostFileFetcher(files: [
            report: Data("%PDF".utf8), over: Data(count: HostFileFetchLimits.automaticLoad + 1),
            huge: Data(count: HostFileFetchLimits.maximumSize + 1),
        ])
        let loads = AgentFileLoads(fetcher: fetcher)

        await loads.load(report, scope: Self.scope)
        await loads.load(report, scope: Self.scope)
        await loads.load(over, scope: Self.scope)
        await loads.load(huge, scope: Self.scope, userRequested: true)

        guard case .loaded = loads.states[report] else { Issue.record("PDF 沒有自動載入"); return }
        #expect(loads.states[over] == .overAutomaticLimit(size: HostFileFetchLimits.automaticLoad + 1))
        #expect(loads.states[huge] == .tooLarge(size: HostFileFetchLimits.maximumSize + 1))
        let reads = await fetcher.requests.filter { if case .read(let path, _, _) = $0 { path == report } else { false } }
        #expect(reads.count == 1, "第二次只查狀態")
    }

    @Test("使用者送出的非圖片檔案:只查狀態(大小),不讀內容;缺檔、被拒、不在上傳資料夾的路徑各有原因(#429)")
    func userFileInfo() async {
        let upload = "/var/folders/zz/demo/T/purrdr-uploads-501/report-1.pdf"
        let cleared = "/var/folders/zz/demo/T/purrdr-uploads-501/cleared-2.zip"
        let scope = HostFileAccessScope(workingDirectories: [], mentionedPaths: [], promptMentionedPaths: [upload, cleared, "/Users/demo/notes.txt"])
        let fetcher = FakeHostFileFetcher(files: [upload: Data(count: 1234)])
        let loads = AgentFileLoads(fetcher: fetcher)

        await loads.inspect(upload, scope: scope)
        await loads.inspect(cleared, scope: scope)
        await loads.inspect("/Users/demo/notes.txt", scope: scope)

        #expect(loads.infos[upload] == .available(size: 1234))
        #expect(loads.infos[cleared] == .missing)
        #expect(loads.infos["/Users/demo/notes.txt"] == .denied)
        #expect(await fetcher.readCount == 0)
    }

    @Test("使用者送出的檔案點開:下載到快取,超過 25 MiB 不下載(#429)")
    func userFileOpens() async {
        let upload = "/var/folders/zz/demo/T/purrdr-uploads-501/data-3.csv"
        let scope = HostFileAccessScope(workingDirectories: [], mentionedPaths: [], promptMentionedPaths: [upload])
        let fetcher = FakeHostFileFetcher(files: [upload: Data("a,b\n".utf8)])
        let loads = AgentFileLoads(fetcher: fetcher, downloadDirectory: FileManager.default.temporaryDirectory.appending(path: "u429-\(UUID().uuidString)"))

        let file = await loads.open(upload, scope: scope)

        #expect(file?.lastPathComponent == "data-3.csv")
        guard case .ready = loads.opens[upload] else { Issue.record("沒有下載好"); return }
    }

    @Test("已送出圖片情境:使用者送出的檔案卡片取自上傳路徑,CSV 還在主機、壓縮檔已被清掉(#429)")
    func sentFilesScenario() async throws {
        let connection = SSHHostConnection(channel: DemoHost(scenario: .sentImages))
        let model = ConversationModel(
            client: HerdrClient(connection: connection), transcripts: TranscriptReader(connection: connection), paneID: "w1:p1",
            knownSessionID: nil, cache: InMemoryConversationCache())
        await model.poll()
        let bubbles = model.items.compactMap { item -> UserBubble? in if case .user(let bubble) = item { bubble } else { nil } }
        let files = bubbles.flatMap(\.filePaths)
        #expect(files == [DemoHostFileFetcher.sentFilePath, DemoHostFileFetcher.clearedFilePath])
        #expect(bubbles.last?.displayText == "And these files.")

        let loads = AgentFileLoads(fetcher: DemoHostFileFetcher())
        for path in files { await loads.inspect(path, scope: model.fileAccessScope) }
        guard case .available = loads.infos[DemoHostFileFetcher.sentFilePath] else { Issue.record("CSV 沒有查到大小"); return }
        #expect(loads.infos[DemoHostFileFetcher.clearedFilePath] == .missing)
    }
}
