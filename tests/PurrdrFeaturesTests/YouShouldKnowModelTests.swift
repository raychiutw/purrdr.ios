#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 「You should know」註記(#23,#37 故事 49–50):讀主機上的 store,動作寫回前每台主機個別同意，可撤掉。
/// 主機是本機 `/bin/sh` + 暫存家目錄。
@MainActor
@Suite("You should know 註記")
struct YouShouldKnowModelTests {
    static let storePath = ".claude/plugins/store/cc-plugin-you-should-know_builtin-0123456789ab.json"
    static let sessionA = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
    static let sessionB = "6ec0bd7f-11c0-43da-975e-2a8ad9ebae0b"
    static let store = """
        {"sessions":[
          {"id":"\(sessionB)","tag":"Heads up","view":{"kind":"explained","line":"Worktrees share objects","text":"One store.","shownAt":1763300000000}},
          {"id":"\(sessionA)","view":{"kind":"offer","line":"Tests run in parallel","explanation":"Use .serialized.","shownAt":1763290000000}}
        ],"known":[],"typedPastInARow":2,"looksToSkip":1}
        """

    let host: LocalShellHost
    let consent = InMemoryHostWriteConsentStore()

    init() throws {
        host = try LocalShellHost.temporary()
    }

    func model() -> YouShouldKnowModel {
        YouShouldKnowModel(host: YouShouldKnowHost(channel: host), hostID: "mac", consent: consent, sleep: { _ in })
    }

    func storeObject() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: host.url(Self.storePath))) as? [String: Any])
    }

    @Test("沒有 store(plugin 沒開):沒有註記，也不報錯")
    func noStore() async {
        let model = model()
        await model.refresh()
        #expect(model.notes.isEmpty)
        #expect(model.message == nil)
    }

    @Test("讀到註記(新→舊),以完整 session id 配對聊天")
    func readsNotes() async throws {
        _ = try host.write(Data(Self.store.utf8), to: Self.storePath)
        let model = model()
        await model.refresh()
        #expect(model.notes.map(\.sessionID) == [Self.sessionB, Self.sessionA])
        #expect(model.note(forSession: Self.sessionA)?.line == "Tests run in parallel")
        #expect(model.count(inSessions: [Self.sessionA, "other"]) == 1)
    }

    @Test("第一次動作先問同意(以哪個使用者修改 store);確認前主機不變")
    func asksConsentBeforeWriting() async throws {
        _ = try host.write(Data(Self.store.utf8), to: Self.storePath)
        let model = model()
        await model.refresh()
        let before = try DirectorySnapshot(of: host.home)
        let note = try #require(model.note(forSession: Self.sessionA))

        await model.perform(.knewIt, on: note)
        #expect(model.pendingConsent?.user == NSUserName())
        #expect(try DirectorySnapshot(of: host.home) == before)

        await model.confirmConsent()
        #expect(model.pendingConsent == nil)
        #expect(consent.isGranted(YouShouldKnowHost.featureID, host: "mac"))
        #expect(try storeObject()["known"] as? [String] == ["Tests run in parallel"])
        #expect(model.note(forSession: Self.sessionA) == nil)
    }

    @Test("取消同意：不寫入，註記還在")
    func cancelConsent() async throws {
        _ = try host.write(Data(Self.store.utf8), to: Self.storePath)
        let model = model()
        await model.refresh()
        let before = try DirectorySnapshot(of: host.home)
        await model.perform(.dismiss, on: try #require(model.note(forSession: Self.sessionA)))
        model.cancelConsent()
        #expect(model.pendingConsent == nil)
        #expect(try DirectorySnapshot(of: host.home) == before)
        #expect(model.notes.count == 2)
    }

    @Test("已同意：深入了解直接寫回，註記換成說明")
    func learnMoreWhenGranted() async throws {
        _ = try host.write(Data(Self.store.utf8), to: Self.storePath)
        consent.grant(YouShouldKnowHost.featureID, host: "mac")
        let model = model()
        await model.refresh()
        await model.perform(.learnMore, on: try #require(model.note(forSession: Self.sessionA)))
        #expect(model.pendingConsent == nil)
        let note = try #require(model.note(forSession: Self.sessionA))
        #expect(note.kind == .explained)
        #expect(note.explanation == "Use .serialized.")
    }

    @Test("註記已被換掉：不寫，說明並重新讀取")
    func staleNote() async throws {
        _ = try host.write(Data(Self.store.utf8), to: Self.storePath)
        consent.grant(YouShouldKnowHost.featureID, host: "mac")
        let model = model()
        await model.refresh()
        var note = try #require(model.note(forSession: Self.sessionA))
        note.shownAt = 1
        await model.perform(.knewIt, on: note)
        #expect(model.message != nil)
        #expect(try storeObject()["known"] as? [String] == [])
    }

    @Test("撤掉 Purrdr 的修改：store 回到第一次寫回前、撤銷同意")
    func undoChanges() async throws {
        _ = try host.write(Data(Self.store.utf8), to: Self.storePath)
        let before = try DirectorySnapshot(of: host.home)
        consent.grant(YouShouldKnowHost.featureID, host: "mac")
        let model = model()
        await model.refresh()
        await model.perform(.knewIt, on: try #require(model.note(forSession: Self.sessionB)))
        #expect(model.isGranted)

        await model.undoChanges()
        #expect(!model.isGranted)
        #expect(!consent.isGranted(YouShouldKnowHost.featureID, host: "mac"))
        #expect(try DirectorySnapshot(of: host.home) == before)
        #expect(model.notes.count == 2)
    }
}
#endif
