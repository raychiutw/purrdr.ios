import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 骨架畫面的載入狀態機(#496):只有「第一次載入、沒有任何內容」才顯示;列數取上次數量;減少動態效果時不脈動。
@MainActor
@Suite("骨架畫面載入狀態")
struct SkeletonLoadingTests {
    @Test("載入中且沒有內容才顯示骨架;有內容(快取或上次的資料)、載入完成都不顯示")
    func shownOnlyWhenLoadingWithoutContent() {
        #expect(SkeletonLoading.isShown(isLoading: true, hasContent: false))
        #expect(!SkeletonLoading.isShown(isLoading: true, hasContent: true))
        #expect(!SkeletonLoading.isShown(isLoading: false, hasContent: false))
        #expect(!SkeletonLoading.isShown(isLoading: false, hasContent: true))
    }

    @Test("骨架列數取上次的數量;沒有紀錄或上次是空的用預設,過少或過多夾在範圍內")
    func rowCountUsesLastCount() {
        #expect(SkeletonLoading.rowCount(lastCount: nil) == SkeletonLoading.defaultRowCount)
        #expect(SkeletonLoading.rowCount(lastCount: 0) == SkeletonLoading.defaultRowCount)
        #expect(SkeletonLoading.rowCount(lastCount: 5) == 5)
        #expect(SkeletonLoading.rowCount(lastCount: 1) == SkeletonLoading.rowCountRange.lowerBound)
        #expect(SkeletonLoading.rowCount(lastCount: 40) == SkeletonLoading.rowCountRange.upperBound)
    }

    @Test("開減少動態效果時不脈動")
    func pulseFollowsReduceMotion() {
        #expect(SkeletonLoading.pulses(reduceMotion: false))
        #expect(!SkeletonLoading.pulses(reduceMotion: true))
    }

    @Test("列數存放處:記憶體與 UserDefaults 都讀得回上次存的數量,各清單互不影響")
    func stores() {
        let memory = InMemorySkeletonRowCountStore()
        #expect(memory.load(.agentList) == nil)
        memory.save(4, for: .agentList)
        #expect(memory.load(.agentList) == 4)
        #expect(memory.load(.files) == nil)

        let suite = "SkeletonLoadingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = UserDefaultsSkeletonRowCountStore(defaults: defaults)
        stored.save(7, for: .agentList)
        #expect(UserDefaultsSkeletonRowCountStore(defaults: defaults).load(.agentList) == 7)
    }

    @Test("聊天列表:骨架列數取上次列表的列數;列表顯示後記住現在的列數")
    func agentListSkeletonRowCount() async throws {
        let store = InMemorySkeletonRowCountStore()
        store.save(4, for: .agentList)
        #expect(MergedAgentListModel(skeletonRowCounts: store).loadingRowCount == 4)

        let clock = AgentListLoadingTests.Clock()
        let fresh = MergedAgentListModel(skeletonRowCounts: InMemorySkeletonRowCountStore())
        #expect(fresh.loadingRowCount == SkeletonLoading.defaultRowCount)
        fresh.update(sources: [
            AgentListLoadingTests.source(
                AgentListLoadingTests.studio, name: "Studio", connection: await AgentListLoadingTests.healthy(), clock: clock)
        ], selected: AgentListLoadingTests.studio)
        await fresh.load()
        #expect(fresh.content == .list)
        #expect(fresh.agentRows.count == 3)
        fresh.rememberRowCount()
        #expect(fresh.loadingRowCount == 3)
    }

    @Test("slash 選單:讀指令清單的第一次(還沒有任何指令)顯示骨架;讀完或背景重讀(已有指令)不顯示")
    func slashMenuSkeleton() async {
        let gate = SkeletonGate()
        let catalog = SlashCatalog(sections: [SlashSection(source: .builtIn, commands: [SlashCommand(name: "clear", summary: "Clear")])], isComplete: true)
        let menu = SlashMenuModel(loader: {
            await gate.wait()
            return catalog
        })
        #expect(!menu.showsSkeleton, "還沒觸發")
        menu.update(draft: "/")
        menu.refreshIfNeeded()
        for _ in 0..<50 where !menu.isLoading { await Task.yield() }
        #expect(menu.isLoading)
        #expect(menu.showsSkeleton)
        await gate.open()
        await menu.load()
        #expect(!menu.isLoading)
        #expect(!menu.showsSkeleton)
    }
}

private actor SkeletonGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
