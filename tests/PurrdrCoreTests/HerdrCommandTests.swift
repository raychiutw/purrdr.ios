import PurrdrCore
import Testing

@Suite("主機指令建構")
struct HerdrCommandTests {
    static let path = #"PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH""#

    @Test("沒設 herdr 路徑與具名 session 時，用 PATH 裡的 herdr、預設 session")
    func defaults() {
        #expect(HerdrCommand.bridge() == "\(Self.path) 'herdr' remote-api-bridge")
        #expect(HerdrInstallation(path: "", session: "").isDefault)
    }

    @Test("具名 session 以 --session 帶入每個 herdr 指令(#37 故事 23)")
    func namedSession() {
        let herdr = HerdrInstallation(path: "~/bin/herdr", session: "work")
        #expect(HerdrCommand.bridge(herdr) == #"\#(Self.path) "$HOME"/'bin/herdr' --session 'work' remote-api-bridge"#)
        #expect(HerdrCommand.version(herdr) == #"\#(Self.path) "$HOME"/'bin/herdr' --version"#)
    }

    @Test("session 空白或 default 都是預設 session;路徑空白是 herdr")
    func blankAndDefaultSession() {
        #expect(HerdrInstallation(path: "  ", session: "default") == HerdrInstallation())
        #expect(HerdrInstallation(path: "", session: " ").session == nil)
    }

    @Test("session 名稱一樣完整引號化")
    func sessionIsQuoted() {
        let herdr = HerdrInstallation(session: "it's")
        #expect(HerdrCommand.bridge(herdr) == #"\#(Self.path) 'herdr' --session 'it'"'"'s' remote-api-bridge"#)
    }

    @Test("更新 herdr 用 update --handoff,讓執行中的伺服器交接到新版")
    func update() {
        #expect(HerdrCommand.update(HerdrInstallation()) == "\(Self.path) 'herdr' update --handoff")
    }
}
