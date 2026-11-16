import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Windows 主機回報的路徑是 `C:\…`(行為規格 §11.1「檔案路徑一律以 `/` 開頭驗證 → 依主機 OS 驗證」)。
/// 驗證規則不變(絕對路徑、沒有 `..` 段、沒有換行),只是兩種寫法都認。
@Suite("Windows 主機的路徑")
struct WindowsHostPathTests {
    @Test("回報的對話紀錄路徑:C:\\… 可以;有 .. 段或不是絕對路徑就不執行任何指令", arguments: [
        (#"C:\Users\demo\.pi\agent\sessions\p\2026_abc.jsonl"#, true),
        (#"D:/work/.pi/agent/sessions/abc.jsonl"#, true),
        (#"C:\Users\demo\..\other\abc.jsonl"#, false),
        (#"Users\demo\abc.jsonl"#, false),
        (#"\\server\share\abc.jsonl"#, false),
    ])
    func reportedTranscriptPath(path: String, valid: Bool) async throws {
        let host = FakeHost()
        let reader = TranscriptReader(channel: host)
        let target = TranscriptTarget(format: .antigravity, location: .reportedPath(path), sessionKey: "k")
        await host.expect(
            TranscriptCommand.locate(.reportedPath(path), readsHeader: false),
            reply: FakeReply(stdout: Data("\(path)\n42\n".utf8)))

        if valid {
            #expect(try await reader.locate(target) == TranscriptFile(path: path, size: 42))
        } else {
            await #expect(throws: TranscriptReadError.invalidReference) { _ = try await reader.locate(target) }
            #expect(await host.executions.isEmpty)
        }
    }

    @Test("Grok 與 Codex 的檔名檢查也認反斜線")
    func grokAndCodexNames() async throws {
        let id = "019a1b2c-3d4e-7f00-8000-000000000001"
        let host = FakeHost()
        let grok = #"C:\Users\demo\.grok\sessions\C--work\"# + id + #"\updates.jsonl"#
        await host.expect(TranscriptCommand.locate(.grok(sessionID: id), readsHeader: false), reply: FakeReply(stdout: Data("\(grok)\n10\n".utf8)))
        let codex = #"C:\Users\demo\.codex\sessions\2026\11\16\rollout-2026-11-16T10-00-00-"# + id + ".jsonl"
        let header = #"{"type":"session_meta","payload":{"id":"\#(id)"}}"#
        await host.expect(
            TranscriptCommand.locate(.codex(sessionID: id), readsHeader: true),
            reply: FakeReply(stdout: Data("\(codex)\n10\n\(header)\n".utf8)))
        let reader = TranscriptReader(channel: host)

        #expect(try await reader.locate(TranscriptTarget(format: .grok, location: .grok(sessionID: id), sessionKey: id)).path == grok)
        #expect(try await reader.locate(TranscriptTarget(format: .codex, location: .codex(sessionID: id), sessionKey: id)).path == codex)
    }

    @Test("subagent 的 session 資料夾：Windows 路徑去掉 \\subagents\\ 之後的部分")
    func sessionFolder() {
        #expect(ClaudeTranscript.sessionFolder(ofTranscript: #"C:\Users\demo\.claude\projects\C--work\abc\subagents\agent-1.jsonl"#)
            == #"C:\Users\demo\.claude\projects\C--work\abc"#)
        #expect(ClaudeTranscript.sessionFolder(ofTranscript: #"C:\Users\demo\.claude\projects\C--work\abc.jsonl"#)
            == #"C:\Users\demo\.claude\projects\C--work\abc"#)
    }

    @Test("圖片上傳：主機回 C:\\…\\.purrdr\\uploads\\<檔名> 就是成功")
    func imageUploadPath() async throws {
        let name = UploadFileName("m3x-abc.jpg")!
        let path = #"C:\Users\Demo User\.purrdr\uploads\m3x-abc.jpg"#
        let host = FakeHost()
        await host.expect(ImageUploadCommand.posix(name: name, size: 3), reply: FakeReply(stdout: Data("\(path)\n".utf8)))

        #expect(try await ImageUploader(channel: host).upload(Data([1, 2, 3]), named: name) == path)
    }

    @Test("prompt 裡的 Windows 上傳路徑(使用者名稱可以有空白)認成圖片")
    func uploadedImageInPrompt() {
        let path = #"C:\Users\Demo User\.purrdr\uploads\m3x-abc.jpg"#
        let extracted = UploadedImages.extract(from: "看這張\n\n" + path)
        #expect(extracted.text == "看這張")
        #expect(extracted.paths == [path])
    }

    @Test("資料夾清單與上傳：Windows 的絕對路徑")
    func folders() async throws {
        let host = FakeHost()
        await host.expect(HostFolderCommand.list(#"C:\Users\demo"#), reply: FakeReply(stdout: Data(
            "C:\\Users\\demo\nd--------- 1 0 0 0 Nov 16 09:05 Desktop\n---------- 1 0 0 12 Jan 2 2024 a b.txt\n".utf8)))
        await host.expect(
            HostFolderCommand.upload(folder: #"C:\Users\demo\Desktop"#, name: "r.pdf", size: 1),
            reply: FakeReply(stdout: Data("C:\\Users\\demo\\Desktop\\r.pdf\n".utf8)))
        let folders = HostFolders(channel: host)

        let listing = try await folders.list(#"C:\Users\demo"#)
        #expect(listing.path == #"C:\Users\demo"#)
        #expect(listing.entries.map(\.name) == ["Desktop", "a b.txt"])
        #expect(try await folders.upload(Data([0]), named: "r.pdf", to: #"C:\Users\demo\Desktop"#) == #"C:\Users\demo\Desktop\r.pdf"#)
    }

    @Test("新增對話的資料夾：Windows 的絕對路徑")
    func newChatFolders() async throws {
        let host = FakeHost()
        await host.expect(NewChatFolders.command(for: "~"), reply: FakeReply(stdout: Data("C:\\Users\\demo\nwork\nDesktop\n".utf8)))

        #expect(try await NewChatFolders(channel: host).list("~") == NewChatFolderListing(path: #"C:\Users\demo"#, folders: ["Desktop", "work"]))
    }

    @Test("Claude 在 Windows 主機上的資料夾信任：以真實畫面為底，只把資料夾換成 C:\\Users\\demo\\weather-app")
    func trustPromptOnWindows() throws {
        let screen = PaneScreens.text("claude-trust").replacingOccurrences(of: "/Users/demo/weather-app", with: #"C:\Users\demo\weather-app"#)
        let prompt = try #require(BlockedPromptParser.parse(screen: screen, agentKind: "claude"))

        #expect(prompt.question == #"Trust C:\Users\demo\weather-app? Claude Code will be able to read, edit, and run files there."#)
    }

    @Test("路徑最後一段(資料夾名稱、workspace 名稱):Windows 路徑以 \\ 分段")
    func lastComponent() {
        #expect(HostPathSyntax.lastComponent(#"C:\Users\demo\weather-app"#) == "weather-app")
        #expect(HostPathSyntax.lastComponent("/Users/demo/weather-app") == "weather-app")
        #expect(HostPathSyntax.lastComponent(#"/Users/demo/a\b"#) == #"a\b"#)
    }

    @Test("去掉結尾的分隔符號：/ 與 \\ 都算，根目錄 / 保留")
    func trimmingTrailingSeparator() {
        #expect(HostPathSyntax.trimmingTrailingSeparator("/Users/demo/") == "/Users/demo")
        #expect(HostPathSyntax.trimmingTrailingSeparator(#"C:\Users\demo\"#) == #"C:\Users\demo"#)
        #expect(HostPathSyntax.trimmingTrailingSeparator("/Users/demo") == "/Users/demo")
        #expect(HostPathSyntax.trimmingTrailingSeparator("/") == "/")
    }
}
