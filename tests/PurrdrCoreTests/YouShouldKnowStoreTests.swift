import Foundation
import PurrdrCore
import Testing

/// 「You should know」註記(#23,行為規格 F17):Claude Code 內建 plugin 的共用 store。
///
/// 格式依主機上 Claude Code 2.1.325 的實際行為(`sessions` 是列的陣列、新的在前;`view.kind` 為 `offer` 或 `explained`
/// 時才是顯示中的註記;`known` 最多 50 句;`typedPastInARow`/`looksToSkip` 是兩個計數器)。
/// 範例內容是自己寫的。
@Suite("You should know 註記(store)")
struct YouShouldKnowStoreTests {
    static let sessionA = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
    static let sessionB = "6ec0bd7f-11c0-43da-975e-2a8ad9ebae0b"

    static let sample = """
        {
          "sessions": [
            {"id": "\(sessionB)", "tag": "Heads up", "view": {"kind": "explained", "line": "git worktrees share one object store", "text": "Each worktree has its own checkout.", "iteration": 1, "shownAt": 1763300000000, "extra": 7}},
            {"id": "\(sessionA)", "view": {"kind": "offer", "line": "Swift Testing runs tests in parallel by default", "explanation": "Use .serialized for shared state.", "shownAt": 1763290000000, "promptsSurvived": 2}},
            {"id": "4a1d3c0e-0000-4000-8000-00000000000c", "view": {"kind": "asked", "line": "old", "shownAt": 1}},
            {"id": "5b2e4d1f-0000-4000-8000-00000000000d"}
          ],
          "known": ["Tabs are not spaces"],
          "seen": ["a", "b"],
          "typedPastInARow": 3,
          "looksToSkip": 2,
          "futureKey": {"nested": [1, 2.5, "x"]}
        }
        """

    func store() throws -> YouShouldKnowStore {
        try #require(YouShouldKnowStore(data: Data(Self.sample.utf8)))
    }

    func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func row(_ data: Data, _ id: String) throws -> [String: Any] {
        let rows = try #require(try object(data)["sessions"] as? [[String: Any]])
        return try #require(rows.first { $0["id"] as? String == id })
    }

    @Test("只有 offer／explained 是顯示中的註記，依時間新→舊")
    func notesNewestFirst() throws {
        let notes = try store().notes
        #expect(notes.map(\.sessionID) == [Self.sessionB, Self.sessionA])
        #expect(notes[0].line == "git worktrees share one object store")
        #expect(notes[0].explanation == "Each worktree has its own checkout.")
        #expect(notes[0].canLearnMore == false)
        #expect(notes[1].canLearnMore == true)
    }

    @Test("以完整 session id 配對註記")
    func noteForSession() throws {
        let store = try store()
        #expect(store.note(forSession: Self.sessionA)?.line == "Swift Testing runs tests in parallel by default")
        #expect(store.note(forSession: String(Self.sessionA.prefix(8))) == nil)
    }

    @Test("深入了解：換成 explained view(text 是說明),其他列與未知鍵保留")
    func learnMore() throws {
        let store = try store()
        let note = try #require(store.note(forSession: Self.sessionA))
        let data = try store.applying(.learnMore, to: note, now: Date(timeIntervalSince1970: 1_763_400_000))
        let view = try #require(try row(data, Self.sessionA)["view"] as? [String: Any])
        #expect(view["kind"] as? String == "explained")
        #expect(view["text"] as? String == "Use .serialized for shared state.")
        #expect(view["line"] as? String == note.line)
        #expect((view["shownAt"] as? NSNumber)?.int64Value == 1_763_400_000_000)
        let root = try object(data)
        #expect((root["futureKey"] as? [String: Any])?["nested"] as? [AnyHashable] == [1, 2.5, "x"] as [AnyHashable])
        #expect((root["sessions"] as? [Any])?.count == 4)
        #expect(try row(data, Self.sessionB)["tag"] as? String == "Heads up")
    }

    @Test("早就知道：移除 view、句子加入 known、計數器歸零")
    func knewIt() throws {
        let store = try store()
        let note = try #require(store.note(forSession: Self.sessionB))
        let data = try store.applying(.knewIt, to: note, now: .now)
        #expect(try row(data, Self.sessionB)["view"] == nil)
        #expect(try row(data, Self.sessionB)["tag"] as? String == "Heads up")
        let root = try object(data)
        #expect(root["known"] as? [String] == ["Tabs are not spaces", "git worktrees share one object store"])
        #expect((root["typedPastInARow"] as? NSNumber)?.intValue == 0)
        #expect((root["looksToSkip"] as? NSNumber)?.intValue == 0)
        #expect(root["seen"] as? [String] == ["a", "b"])
        #expect(YouShouldKnowStore(data: data)?.note(forSession: Self.sessionB) == nil)
    }

    @Test("known 不分大小寫去重，最多保留最後 50 句")
    func knownDeduplicatedAndCapped() throws {
        var root = try object(Data(Self.sample.utf8))
        root["known"] = (0..<50).map { "Line \($0)" } + ["GIT WORKTREES SHARE ONE OBJECT STORE"]
        let base = try #require(YouShouldKnowStore(data: try JSONSerialization.data(withJSONObject: root)))
        let note = try #require(base.note(forSession: Self.sessionB))
        let known = try object(try base.applying(.knewIt, to: note, now: .now))["known"] as? [String]
        #expect(known?.count == 50)
        #expect(known?.last == "GIT WORKTREES SHARE ONE OBJECT STORE")

        let fresh = try store()
        let other = try object(try fresh.applying(.knewIt, to: try #require(fresh.note(forSession: Self.sessionA)), now: .now))["known"] as? [String]
        #expect(other?.count == 2)
    }

    @Test("略過：只移除 view,不加入 known、不動計數器")
    func dismiss() throws {
        let store = try store()
        let data = try store.applying(.dismiss, to: try #require(store.note(forSession: Self.sessionA)), now: .now)
        #expect(try row(data, Self.sessionA)["view"] == nil)
        let root = try object(data)
        #expect(root["known"] as? [String] == ["Tabs are not spaces"])
        #expect((root["typedPastInARow"] as? NSNumber)?.intValue == 3)
    }

    @Test("該列已經不是同一則註記(kind/line/shownAt 變了)時不套用")
    func staleNoteRejected() throws {
        let store = try store()
        var note = try #require(store.note(forSession: Self.sessionA))
        note.shownAt = 42
        #expect(throws: YouShouldKnowError.noteChanged) { try store.applying(.knewIt, to: note, now: .now) }
    }

    @Test("在聊天中討論的草稿：plugin 自己的格式(引言 + 引用的標籤、句子與說明)")
    func discussionDraft() throws {
        let note = try #require(try store().note(forSession: Self.sessionB))
        #expect(note.discussionDraft == """
            Here is a note offered by a side agent:
            > Heads up · git worktrees share one object store
            > Each worktree has its own checkout.
            """)
    }

    @Test("不是 JSON 物件就不是 store")
    func invalidStore() {
        #expect(YouShouldKnowStore(data: Data("[1]".utf8)) == nil)
        #expect(YouShouldKnowStore(data: Data("{".utf8)) == nil)
        #expect(YouShouldKnowStore(data: Data("{}".utf8))?.notes == [])
    }
}
