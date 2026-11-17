import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 即時追蹤的分段追趕(#130,行為規格 F5.3、R-B08、R-B09、R-B15)。Agent 一次寫出很多內容時，畫面上的訊息
/// 與往上翻載入的舊頁都要留著，新訊息依序接在後面;只有真正的斷層才重建。
/// 對話紀錄腳本在本機對真實檔案執行(`RoutingHost`),內容以真實 Claude Code 對話紀錄的 fixture 為底。
@MainActor
@Suite("對話閱讀：分段追趕")
struct ConversationCatchUpTests {
    typealias Base = ConversationModelTests

    /// 以 fixture 第 6 行(使用者打的字)為底，換掉 uuid 與內容，當作 Agent 工作中寫出的新訊息。
    /// `bytes` 是內容的大約 byte 數(中文每字 3 bytes)。
    static func userLine(_ index: Int, bytes: Int) -> String {
        let text = "第 \(index) 則" + String(repeating: "很長的輸出", count: max(1, bytes / 15))
        return Base.fixtureLines[6]
            .replacingOccurrences(of: "00000000-0000-4000-8000-000000000008", with: String(format: "00000000-0000-4000-8000-0000000a%04x", index))
            .replacingOccurrences(of: "幫我把 CSV 匯出整理一下 🧾", with: text)
    }

    /// 閒置的 Claude Code 每次輪詢讀 snapshot 與一次畫面(找建議提示詞,#123)。
    static func pollIdle(_ setup: Base.Setup, times: Int = 1) async {
        for _ in 0..<times {
            await setup.host.bridge.expect(Base.bridge, reply: Base.snapshot())
            await setup.host.bridge.expect(Base.bridge, reply: Base.noSuggestionScreen)
            await setup.model.poll()
        }
    }

    static func userTexts(_ items: [ConversationItem]) -> [String] {
        items.compactMap { if case .user(let bubble) = $0 { String(bubble.text.prefix(while: { $0 != "很" })) } else { nil } }
    }

    /// 根因(#130):每次輪詢落後超過 64 KiB 就改讀最後一個視窗並取代，連往上翻的舊頁一起丟掉。
    @Test("即時追蹤：一次寫入超過 64 KiB 時，原有訊息與往上翻的舊頁都在，新訊息依序接在後面")
    func largeWriteKeepsShownAndOlderMessages() async throws {
        let setup = try Base.setup(openLines: 4, pageLines: 5)
        await Self.pollIdle(setup)
        await setup.model.loadOlder()
        let before = setup.model.items.map(\.id)
        #expect(before.count > 2)

        // 共約 420 KiB:超過 64 KiB,也超過單次上限(要分好幾次輪詢);其中一行(300 KiB)本身比單次上限大。
        let sizes = [20 << 10, 30 << 10, 300 << 10, 20 << 10, 50 << 10]
        let added = sizes.enumerated().map { Self.userLine($0.offset + 1, bytes: $0.element) }
        try setup.shell.append(Data(added.map { $0 + "\n" }.joined().utf8), to: Base.transcriptPath)

        for _ in 0..<6 {
            await Self.pollIdle(setup)
            // 每次輪詢後畫面上原有的訊息(含往上翻的舊頁)都還在，順序不變。
            #expect(Array(setup.model.items.map(\.id).prefix(before.count)) == before)
        }

        #expect(Self.userTexts(setup.model.items).suffix(5) == ["第 1 則", "第 2 則", "第 3 則", "第 4 則", "第 5 則"])
        #expect(setup.model.items.count == before.count + 5)
        #expect(setup.model.banner == nil)
        let windows = await setup.host.shellCommands.filter { $0.contains("print \"more\"") }
        #expect(windows.count == 2, "只有開啟與往上翻讀視窗，追蹤不改讀新視窗")
    }

    /// R-B09:檔案變小(被換掉)是真正的斷層，重建列表。
    @Test("斷層：檔案變小時重建為新內容")
    func shrunkFileRebuilds() async throws {
        let setup = try Base.setup()
        await Self.pollIdle(setup)
        #expect(setup.model.items.count == Base.fixtureItemCount)

        try setup.shell.write(Data((Self.userLine(1, bytes: 30) + "\n").utf8), to: Base.transcriptPath)
        await Self.pollIdle(setup)

        #expect(Self.userTexts(setup.model.items) == ["第 1 則"])
        #expect(setup.model.items.count == 1)
    }

    /// F5.3 第 3 點、R-B08:重新開啟(從快取恢復)時落差大，不逐段重播積壓，讀新視窗。
    @Test("重新開啟：從快取恢復時落後超過 64 KiB,讀新視窗")
    func reopenFarBehindReadsNewWindow() async throws {
        let cache = InMemoryConversationCache()
        let first = try Base.setup(cache: cache)
        await Self.pollIdle(first)

        let second = try Base.setup(cache: cache)
        let added = (1...4).map { Self.userLine($0, bytes: 30 << 10) }
        // 快取記的是第一次開啟的檔案。
        try first.shell.append(Data(added.map { $0 + "\n" }.joined().utf8), to: Base.transcriptPath)
        await second.model.restoreFromCache()
        await Self.pollIdle(second)

        let commands = await second.host.shellCommands
        #expect(commands.contains { $0.contains("print \"more\"") }, "讀了新視窗")
        #expect(Self.userTexts(second.model.items).suffix(4) == ["第 1 則", "第 2 則", "第 3 則", "第 4 則"])
    }
}
