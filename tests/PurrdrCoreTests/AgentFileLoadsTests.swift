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
}
