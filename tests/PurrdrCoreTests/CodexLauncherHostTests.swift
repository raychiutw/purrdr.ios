#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// Codex 啟動器的主機端(行為規格 §4.2「Session 回報」,ADR-0002 的寫入例外)。【未實測】
///
/// 在本機用真的 `/bin/sh` 跑，家目錄是暫存資料夾(`LocalShellHost`);絕不碰執行測試的人真正的家目錄。
@Suite("Codex 啟動器(主機)")
struct CodexLauncherHostTests {
    /// 假的 Codex:每個參數印一行。
    static let fakeCodex = "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n"

    let host: LocalShellHost
    let launcher: CodexLauncherHost

    init() throws {
        host = try LocalShellHost.temporary()
        launcher = CodexLauncherHost(channel: host)
    }

    func write(_ text: String, to path: String, mode: Int = 0o644) throws {
        let url = try host.write(Data(text.utf8), to: path)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// 以 `env` 執行(`$HOME/.local/bin` 在 PATH 最前面，真的 Codex 在 `$HOME/real-bin`)。
    func run(_ command: String, env: String = "") async throws -> (stdout: String, exit: Int32?) {
        let session = try await host.execute(#"PATH="$HOME/.local/bin:$HOME/real-bin:/usr/bin:/bin" \#(env) \#(command)"#)
        var stdout = Data()
        var exit: Int32?
        for try await event in session.output {
            switch event {
            case .stdout(let data): stdout.append(data)
            case .stderr: break
            case .exit(let code, _): exit = code
            }
        }
        return (String(decoding: stdout, as: UTF8.self), exit)
    }

    // MARK: - 安裝與還原

    /// ADR-0002:可以完整移除。`~/.local/bin` 原本不存在時由安裝建立，還原時一起移除。
    @Test("~/.local 不存在時：安裝建立 ~/.local/bin/codex;還原後主機與安裝前完全相同")
    func installCreatesFoldersAndRestoreRemovesThem() async throws {
        try write("notes\n", to: "Documents/todo.txt")
        let before = try DirectorySnapshot(of: host.home)

        let inspection = try await launcher.inspect()
        #expect(inspection.isInstalled == false)
        try await launcher.install()

        let installed = host.url(".local/bin/codex")
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
        #expect(try await launcher.inspect().isInstalled)

        try await launcher.restore()

        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("~/.local/bin 原本就有：還原只拿掉啟動器，資料夾與其他檔案不動")
    func existingFolderIsKept() async throws {
        try write("#!/bin/sh\n", to: ".local/bin/other-tool", mode: 0o755)
        let before = try DirectorySnapshot(of: host.home)

        try await launcher.install()
        try await launcher.restore()

        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("安裝後使用者在 Purrdr 建的資料夾放了自己的檔案：還原拿掉啟動器，但保留資料夾與使用者的檔案")
    func userFilesInCreatedFolderAreKept() async throws {
        try await launcher.install()
        try write("#!/bin/sh\n", to: ".local/bin/mine", mode: 0o755)

        try await launcher.restore()

        #expect(!FileManager.default.fileExists(atPath: host.url(".local/bin/codex").path))
        #expect(FileManager.default.fileExists(atPath: host.url(".local/bin/mine").path))
        #expect(!FileManager.default.fileExists(atPath: host.url(".purrdr").path))
    }

    @Test("安裝後使用者把 ~/.local/bin/codex 換成自己的：還原不刪它")
    func replacedLauncherIsKept() async throws {
        try await launcher.install()
        try write("#!/bin/sh\necho mine\n", to: ".local/bin/codex", mode: 0o755)

        try await launcher.restore()

        #expect(try String(contentsOf: host.url(".local/bin/codex"), encoding: .utf8) == "#!/bin/sh\necho mine\n")
        #expect(!FileManager.default.fileExists(atPath: host.url(".purrdr").path))
    }

    /// 不覆蓋使用者自己的 Codex(例如裝在 ~/.local/bin 的那一份):什麼都不改。
    @Test("~/.local/bin/codex 已經是別的檔案：拒絕安裝，主機不變")
    func refusesToReplaceExistingCodex() async throws {
        try write("#!/bin/sh\necho real codex\n", to: ".local/bin/codex", mode: 0o755)
        let before = try DirectorySnapshot(of: host.home)

        await #expect(throws: CodexLauncherError.codexAlreadyThere) { try await launcher.inspect() }
        await #expect(throws: CodexLauncherError.codexAlreadyThere) { try await launcher.install() }

        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("重複安裝不會把啟動器當成原本的;還原仍回到第一次安裝前")
    func reinstallKeepsOriginalState() async throws {
        let before = try DirectorySnapshot(of: host.home)

        try await launcher.install()
        try await launcher.install()
        try await launcher.restore()

        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    // MARK: - 啟動器的行為

    /// herdr 的 pane 身分以 `-c shell_environment_policy.set.*` 帶進 Codex(值是 TOML 字串)。
    @Test("在 herdr pane 裡：把 HERDR_ENV、HERDR_PANE_ID、HERDR_SOCKET_PATH 以 -c 帶給真的 Codex,參數原樣接在後面")
    func launcherPassesPaneIdentity() async throws {
        try write(Self.fakeCodex, to: "real-bin/codex", mode: 0o755)
        try await launcher.install()

        let result = try await run("codex resume 'a b'", env: #"HERDR_ENV=1 HERDR_PANE_ID=w3:p1 HERDR_SOCKET_PATH='/tmp/her"dr.sock'"#)

        #expect(result.exit == 0)
        #expect(result.stdout.split(separator: "\n") == [
            "-c", #"shell_environment_policy.set.HERDR_ENV="1""#,
            "-c", #"shell_environment_policy.set.HERDR_PANE_ID="w3:p1""#,
            "-c", #"shell_environment_policy.set.HERDR_SOCKET_PATH="/tmp/her\"dr.sock""#,
            "resume", "a b",
        ])
    }

    @Test("不在 herdr pane 裡：原樣交給真的 Codex")
    func launcherOutsideHerdrIsTransparent() async throws {
        try write(Self.fakeCodex, to: "real-bin/codex", mode: 0o755)
        try await launcher.install()

        let result = try await run("codex exec hi")

        #expect(result.stdout == "exec\nhi\n")
    }

    @Test("PATH 上找不到真的 Codex:exit 127,不會呼叫自己")
    func launcherWithoutRealCodex() async throws {
        try await launcher.install()

        let result = try await run("codex", env: "HERDR_PANE_ID=w3:p1")

        #expect(result.exit == 127)
    }
}
#endif
