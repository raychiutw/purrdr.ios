import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 註記的定期讀取(#161):帶已知版本、沒變不傳;同一台主機只一個讀取者;看的畫面都離開(進背景)就停。
@MainActor
@Suite("You should know 註記的定期讀取")
struct YouShouldKnowPollingTests {
    static let storePath: HostPath = ".claude/plugins/store/cc-plugin-you-should-know_builtin-0123456789ab.json"
    static let store = """
        {"sessions":[{"id":"1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed","view":{"kind":"offer","line":"Tests run in parallel","shownAt":1}}],"known":[]}
        """

    /// 記錄每次讀 store 時帶的已知版本;版本與目前相同就回 unchanged。
    actor CountingHost: YouShouldKnowHosting {
        private(set) var knownVersions: [HostFileVersion?] = []
        var version = HostFileVersion(checksum: "v1:10")

        var reads: Int { knownVersions.count }

        func locate() async throws -> HostPath? { YouShouldKnowPollingTests.storePath }

        func read(_ path: HostPath) async throws -> YouShouldKnowStore? { YouShouldKnowStore(data: Data(YouShouldKnowPollingTests.store.utf8)) }

        func read(_ path: HostPath, ifChangedFrom known: HostFileVersion?) async throws -> HostFileUpdate<YouShouldKnowStore?> {
            knownVersions.append(known)
            if known == version { return .unchanged }
            return .changed(YouShouldKnowStore(data: Data(YouShouldKnowPollingTests.store.utf8)), version: version)
        }

        func user() async throws -> String { "ray" }
        func perform(_ action: YouShouldKnowAction, on note: YouShouldKnowNote, at path: HostPath) async throws {}
        func restore() async throws {}
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<2000 where !(await condition()) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }

    @Test("第二次讀帶上次讀到的版本;主機回沒變時註記照舊")
    func secondReadCarriesKnownVersion() async throws {
        let host = CountingHost()
        let model = YouShouldKnowModel(host: host, hostID: "mac", consent: InMemoryHostWriteConsentStore(), sleep: { _ in })

        await model.refresh()
        await model.refresh()

        #expect(await host.knownVersions == [nil, HostFileVersion(checksum: "v1:10")])
        #expect(model.notes.map(\.line) == ["Tests run in parallel"])
    }

    @Test("列表與聊天輸入列同時看同一台主機：只有一個讀取迴圈")
    func listAndComposerShareOneReader() async throws {
        let host = CountingHost()
        let sleeper = RecordingSleeper()
        let model = YouShouldKnowModel(host: host, hostID: "mac", consent: InMemoryHostWriteConsentStore(), sleep: sleeper.sleep)

        let list = Task { await model.liveUpdates.attach() }
        let composer = Task { await model.liveUpdates.attach() }
        try await waitUntil { await sleeper.requested.count >= 1 && model.liveUpdates.viewers == 2 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await host.reads == 1)
        #expect(await sleeper.requested == [YouShouldKnowModel.pollInterval])
        list.cancel()
        composer.cancel()
    }

    @Test("看的畫面都離開(進背景)就不再讀;回來(回前景)立刻再讀")
    func stopsInBackgroundAndResumesInForeground() async throws {
        let host = CountingHost()
        let model = YouShouldKnowModel(host: host, hostID: "mac", consent: InMemoryHostWriteConsentStore(),
                                       sleep: { _ in try await Task.sleep(for: .milliseconds(10)) })

        let foreground = Task { await model.liveUpdates.attach() }
        try await waitUntil { await host.reads >= 2 }
        foreground.cancel()
        try await waitUntil { model.liveUpdates.viewers == 0 }
        try await Task.sleep(for: .milliseconds(30))
        let readsWhenBackgrounded = await host.reads
        try await Task.sleep(for: .milliseconds(100))
        #expect(await host.reads == readsWhenBackgrounded, "背景時不該再讀")

        let again = Task { await model.liveUpdates.attach() }
        try await waitUntil { await host.reads > readsWhenBackgrounded }
        again.cancel()
    }
}
