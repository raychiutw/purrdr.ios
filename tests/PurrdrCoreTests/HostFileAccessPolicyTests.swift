import Foundation
import PurrdrCore
import Testing

/// 主機取檔的存取規則(#225),app 端:只讀 Agent 工作目錄之下或對話紀錄中出現過的檔案，排除清單一律不讀。
/// 主機端腳本另外解析 symlink 後再檢查一次(`HostFileFetchScriptTests`)。
@Suite("主機取檔的存取規則(app 端)")
struct HostFileAccessPolicyTests {
    static let scope = HostFileAccessScope(
        workingDirectories: ["/Users/demo/ledger"],
        mentionedPaths: ["/tmp/shot.png", "/Users/demo/.ssh/id_ed25519", "/Users/demo/.SSH/config"])

    @Test("工作目錄之下：允許，主機端要以這個工作目錄解析 symlink 後再比對")
    func insideWorkingDirectory() {
        #expect(HostFileAccessPolicy.decision(for: "/Users/demo/ledger/docs/preview.png", in: Self.scope)
            == .allowed(HostFileTarget(path: "/Users/demo/ledger/docs/preview.png", root: "/Users/demo/ledger")))
    }

    @Test("工作目錄之外、對話紀錄沒出現過：拒絕;名稱開頭相同的兄弟資料夾不算在工作目錄之下")
    func outsideWorkingDirectory() {
        #expect(HostFileAccessPolicy.decision(for: "/Users/demo/notes/a.png", in: Self.scope) == .denied)
        #expect(HostFileAccessPolicy.decision(for: "/Users/demo/ledger-private/a.png", in: Self.scope) == .denied)
    }

    @Test("對話紀錄出現過的路徑：允許，不帶工作目錄")
    func mentionedPath() {
        #expect(HostFileAccessPolicy.decision(for: "/tmp/shot.png", in: Self.scope) == .allowed(HostFileTarget(path: "/tmp/shot.png", root: nil)))
    }

    @Test("排除清單：即使在對話紀錄出現過也拒絕(不分大小寫)")
    func excludedEvenIfMentioned() {
        #expect(HostFileAccessPolicy.decision(for: "/Users/demo/.ssh/id_ed25519", in: Self.scope) == .denied)
        #expect(HostFileAccessPolicy.decision(for: "/Users/demo/.SSH/config", in: Self.scope) == .denied)
        let excluded = [
            "/Users/demo/ledger/.aws/credentials", "/Users/demo/ledger/.purrdr/host-service/devices.json",
            "/Users/demo/ledger/.purrdr/push-4F2A/pairing", "/Users/demo/ledger/Library/Keychains/login.keychain-db",
            "/Users/demo/ledger/.config/gcloud/credentials.db", "/Users/demo/ledger/.codex/auth.json",
            "/Users/demo/ledger/.claude/.credentials.json", "/Users/demo/ledger/.netrc",
        ]
        #expect(excluded.filter { HostFileAccessPolicy.decision(for: $0, in: Self.scope) != .denied } == [])
    }

    @Test("Purrdr 上傳的圖片不在排除清單(Agent 常讀使用者附的圖)")
    func uploadsAreNotExcluded() {
        let scope = HostFileAccessScope(workingDirectories: [], mentionedPaths: ["/Users/demo/.purrdr/uploads/a1.jpg"])
        #expect(HostFileAccessPolicy.decision(for: "/Users/demo/.purrdr/uploads/a1.jpg", in: scope)
            == .allowed(HostFileTarget(path: "/Users/demo/.purrdr/uploads/a1.jpg", root: nil)))
    }

    @Test("新的上傳資料夾(含 TMPDIR 不在標準位置時)與舊的 .purrdr/uploads 都放行;名稱像的資料夾不放行")
    func temporaryUploadFolders() {
        let allowed = ["/var/folders/zz/demo/T/purrdr-uploads-501/a1.jpg", "/run/user/1000/purrdr-uploads-1000/a1.jpg",
                       #"C:\Users\demo\AppData\Local\Temp\purrdr-uploads\a1.jpg"#, "/home/demo/.purrdr/uploads/a1.jpg"]
        for path in allowed {
            let scope = HostFileAccessScope(workingDirectories: [], mentionedPaths: [path])
            #expect(HostFileAccessPolicy.decision(for: path, in: scope) == .allowed(HostFileTarget(path: path, root: nil)), "\(path)")
        }
        for path in ["/run/user/1000/purrdr-uploads-x/a1.jpg", "/home/demo/my-purrdr-uploads/a1.jpg"] {
            let scope = HostFileAccessScope(workingDirectories: [], mentionedPaths: [path])
            #expect(HostFileAccessPolicy.decision(for: path, in: scope) == .denied, "\(path)")
        }
    }

    @Test("Windows 主機(#226):工作目錄比對不分大小寫、`\\` 與 `/` 都是分隔，帶原本的工作目錄給主機")
    func windowsWorkingDirectory() {
        let scope = HostFileAccessScope(workingDirectories: [#"C:\Users\Demo\Ledger"#], mentionedPaths: [])
        #expect(HostFileAccessPolicy.decision(for: #"c:\users\demo\ledger\docs\a.png"#, in: scope)
            == .allowed(HostFileTarget(path: #"c:\users\demo\ledger\docs\a.png"#, root: #"C:\Users\Demo\Ledger"#)))
        #expect(HostFileAccessPolicy.decision(for: "C:/Users/Demo/Ledger/docs/a.png", in: scope)
            == .allowed(HostFileTarget(path: "C:/Users/Demo/Ledger/docs/a.png", root: #"C:\Users\Demo\Ledger"#)))
    }

    @Test("Windows 主機(#226):別的磁碟機、名稱開頭相同的兄弟資料夾、`..`、UNC 拒絕;排除清單不分大小寫")
    func windowsDenied() {
        let scope = HostFileAccessScope(workingDirectories: [#"C:\Users\Demo\Ledger"#], mentionedPaths: [#"\\server\share\a.png"#])
        let paths = [
            #"D:\Users\Demo\Ledger\a.png"#, #"C:\Users\Demo\Ledger-private\a.png"#, #"C:\Users\Demo\Ledger\..\.ssh\id_rsa"#,
            #"\\server\share\a.png"#, #"C:\Users\Demo\Ledger\.SSH\config"#, #"C:\Users\Demo\Ledger\.Purrdr\Push-1\pairing"#,
        ]
        #expect(paths.filter { HostFileAccessPolicy.decision(for: $0, in: scope) != .denied } == [])
    }

    @Test("相對路徑、`..`、`.`、控制字元一律拒絕")
    func malformedPaths() {
        let scope = HostFileAccessScope(workingDirectories: ["/Users/demo/ledger"], mentionedPaths: [])
        let paths = ["docs/a.png", "/Users/demo/ledger/../.ssh/id_rsa", "/Users/demo/ledger/./a.png", "/Users/demo/ledger/a\n.png", ""]
        #expect(paths.filter { HostFileAccessPolicy.decision(for: $0, in: scope) != .denied } == [])
    }
}
