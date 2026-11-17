import Foundation
import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import Testing

/// Demo 主機的主機主題與「You should know」註記(#23;行為規格 F21:Demo 演不出來的功能先加 Demo 情境)。
@Suite("Demo 主機：主題與註記")
struct DemoThemeAndNotesTests {
    @Test("Demo 的 herdr 主題是 tokyo-night;參考檔裝上後可完整移除")
    func demoTheme() async throws {
        let demo = DemoHost()
        let theme = HostThemeHost(channel: demo)
        #expect(try await theme.readTheme().name == "tokyo-night")
        #expect(try await theme.inspect() == HostThemeInspection(user: "demo", isInstalled: false))
        try await theme.install()
        #expect(try await theme.inspect().isInstalled)
        try await theme.restore()
        #expect(try await theme.inspect().isInstalled == false)
    }

    @Test("Demo 有一則給 ledger(w1:p1)的註記，可以「早就知道」並還原")
    func demoNote() async throws {
        let demo = DemoHost()
        let ysk = YouShouldKnowHost(channel: demo)
        let path = try #require(try await ysk.locate())
        let store = try #require(try await ysk.read(path))
        let note = try #require(store.note(forSession: "d3m0d3m0-0000-4000-8000-000000000001"))
        #expect(note.canLearnMore)
        #expect(store.notes.count == 1)

        try await ysk.perform(.knewIt, on: note, at: path)
        #expect(try await ysk.read(path)?.notes.isEmpty == true)
        try await ysk.restore()
        #expect(try await ysk.read(path)?.notes.count == 1)
    }
}
