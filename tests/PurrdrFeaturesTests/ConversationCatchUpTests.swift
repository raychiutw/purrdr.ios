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

    /// #130 review 1:畫面重新可見(回前景、重新進入聊天;`run()` 開始時 `reopen()`)當作重新開啟。離開期間落後超過
    /// 64 KiB 就讀新視窗，不逐段重播積壓(R-B08、F5.3 第 3 點)。
    @Test("重新可見：離開期間落後超過 64 KiB,回來後讀新視窗而不逐段重播")
    func reopenWhileBoundFarBehindReadsNewWindow() async throws {
        let setup = try Base.setup()
        await Self.pollIdle(setup)
        let added = (1...4).map { Self.userLine($0, bytes: 30 << 10) }
        try setup.shell.append(Data(added.map { $0 + "\n" }.joined().utf8), to: Base.transcriptPath)

        await setup.model.reopen()
        await Self.pollIdle(setup)

        let windows = await setup.host.shellCommands.filter { $0.contains("print \"more\"") }
        #expect(windows.count == 2, "開啟一次、回來後讀新視窗一次")
        #expect(Self.userTexts(setup.model.items).suffix(4) == ["第 1 則", "第 2 則", "第 3 則", "第 4 則"])
    }

    /// #130 review 10:從快取恢復後，檔案長大但只有未完成的行不算追上;之後一次寫很多仍讀新視窗。
    @Test("重新開啟：只讀到未完成的行不算追上，之後落後超過 64 KiB 仍讀新視窗")
    func partialLineDoesNotCountAsCaughtUp() async throws {
        let cache = InMemoryConversationCache()
        let first = try Base.setup(cache: cache)
        await Self.pollIdle(first)

        let second = try Base.setup(cache: cache)
        let line = Self.userLine(1, bytes: 30)
        let half = line.utf8.count / 2
        try first.shell.append(Data(line.utf8.prefix(half)), to: Base.transcriptPath)
        await second.model.restoreFromCache()
        await Self.pollIdle(second)

        let rest = Data(line.utf8.dropFirst(half)) + Data(("\n" + (2...5).map { Self.userLine($0, bytes: 30 << 10) + "\n" }.joined()).utf8)
        try first.shell.append(rest, to: Base.transcriptPath)
        await Self.pollIdle(second)

        let commands = await second.host.shellCommands
        #expect(commands.contains { $0.contains("print \"more\"") }, "讀了新視窗")
        #expect(Self.userTexts(second.model.items).suffix(5) == ["第 1 則", "第 2 則", "第 3 則", "第 4 則", "第 5 則"])
    }

    /// #130 review 3:Agent 一次寫出很多(約 1.2 MiB)時，落後很多的下一次讀大一點，幾次輪詢就追上(不是每次只讀 256 KiB)。
    @Test("高速輸出：落後很多時下一次讀大一點，三次輪詢內追上約 1.2 MiB")
    func largeBacklogCatchesUpWithinFewPolls() async throws {
        let setup = try Base.setup()
        await Self.pollIdle(setup)
        let added = (1...40).map { Self.userLine($0, bytes: 30 << 10) }
        try setup.shell.append(Data(added.map { $0 + "\n" }.joined().utf8), to: Base.transcriptPath)

        await Self.pollIdle(setup, times: 3)

        #expect(Self.userTexts(setup.model.items).suffix(2) == ["第 39 則", "第 40 則"])
        #expect(setup.model.items.count == Base.fixtureItemCount + 40)
    }

    /// #130 review 6:跟隨尾端時，記憶體裡的訊息有上限：修剪最舊的整段，修剪後可以往上翻回來，順序與內容都不缺。
    /// 快取也最多 500 則(R-B13),從快取恢復後往上翻同樣接得上。
    @Test("訊息上限：跟隨尾端時修剪最舊的，往上翻可以讀回來;快取最多 500 則且接得上")
    func followingTrimsOldestAndOlderPagesBringThemBack() async throws {
        let cache = InMemoryConversationCache()
        let setup = try Base.setup(cache: cache, openLines: 4, pageLines: 200)
        await Self.pollIdle(setup)
        for batch in 0..<3 {
            let added = (1...250).map { Self.userLine(batch * 250 + $0, bytes: 30) }
            try setup.shell.append(Data(added.map { $0 + "\n" }.joined().utf8), to: Base.transcriptPath)
            await Self.pollIdle(setup)
        }
        let expected = (1...750).map { "第 \($0) 則" }

        #expect(setup.model.items.count <= ConversationModel.followingMessageLimit)
        #expect(Self.userTexts(setup.model.items).last == "第 750 則")
        #expect(setup.model.older == .available)
        while setup.model.older == .available { await setup.model.loadOlder() }
        #expect(Self.userTexts(setup.model.items).suffix(750) == ArraySlice(expected))

        let cached = try #require(await cache.load(chatKey: Base.paneID))
        #expect(cached.messages.count <= CachedConversation.maxMessages)
        let restored = try Base.setup(cache: cache, openLines: 4, pageLines: 200)
        try restored.shell.write(Data(contentsOf: setup.shell.home.appending(path: Base.transcriptPath)), to: Base.transcriptPath)
        await restored.model.restoreFromCache()
        while restored.model.older == .available { await restored.model.loadOlder() }
        #expect(Self.userTexts(restored.model.items).suffix(750) == ArraySlice(expected))
    }

    /// 閱讀中(往上翻在看舊訊息)不修剪：讀者正在看的訊息不會被拿掉。
    @Test("訊息上限：閱讀中不修剪")
    func readingDoesNotTrim() async throws {
        let setup = try Base.setup(openLines: 4)
        await Self.pollIdle(setup)
        setup.model.isFollowingLatest = false
        for batch in 0..<3 {
            let added = (1...250).map { Self.userLine(batch * 250 + $0, bytes: 30) }
            try setup.shell.append(Data(added.map { $0 + "\n" }.joined().utf8), to: Base.transcriptPath)
            await Self.pollIdle(setup)
        }

        #expect(setup.model.items.count > ConversationModel.followingMessageLimit)
        #expect(Self.userTexts(setup.model.items).suffix(750) == ArraySlice((1...750).map { "第 \($0) 則" }))
        #expect(setup.model.older == .available)
    }

    /// #130 review 9:畫面觀察列表的結構變更計數，而不是每次 body 都配置整個 id 陣列;計數只在列(id 與順序)改變時遞增。
    @Test("結構變更計數：沒有新內容不變，接上新訊息時遞增")
    func entriesRevisionChangesOnlyWithEntries() async throws {
        let setup = try Base.setup()
        await Self.pollIdle(setup)
        let opened = setup.model.entriesRevision

        await Self.pollIdle(setup)
        #expect(setup.model.entriesRevision == opened)

        try setup.shell.append(Data((Self.userLine(1, bytes: 30) + "\n").utf8), to: Base.transcriptPath)
        await Self.pollIdle(setup)
        #expect(setup.model.entriesRevision != opened)
    }
}
