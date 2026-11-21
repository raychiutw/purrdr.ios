import Foundation
@testable import PurrdrCore
@testable import PurrdrSSH
import PurrdrTestSupport
import Testing

#if os(macOS)

/// SSH 主機的變更頁(#310):經主機通道跑唯讀 git 指令。以 `LocalShellHost` 對暫存 repo 實跑同一份腳本。
@Suite("SSH 主機的 git 變更")
struct SSHGitChangesTests {
    let host: LocalShellHost
    let repo: URL

    init() throws {
        host = try LocalShellHost.temporary()
        repo = host.url("project")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try host.write(Data("# Garden\n\nWater daily.\n".utf8), to: "project/README.md")
        try host.write(Data("old\n".utf8), to: "project/gone.txt")
        try host.write(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]), to: "project/logo.png")
        try host.write(Data("SECRET=1\n".utf8), to: "project/config/.env")
        try git("add", "-A")
        try git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init")
    }

    private func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repo
        process.environment = ["HOME": host.home.path(percentEncoded: false), "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
    }

    private var cwd: String { repo.path(percentEncoded: false) }
    private var changes: SSHGitChanges { SSHGitChanges(channel: host) }

    /// 改一個、刪一個、新增已加入 index 的、未追蹤的、二進位與排除清單裡的檔案。
    private func makeChanges() throws {
        try host.write(Data("# Garden\n\nWater twice daily.\n".utf8), to: "project/README.md")
        try FileManager.default.removeItem(at: host.url("project/gone.txt"))
        try host.write(Data("let x = 1\n".utf8), to: "project/src/new.swift")
        try git("add", "src/new.swift")
        try host.write(Data("draft\n".utf8), to: "project/notes/todo.md")
        try host.write(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x02]), to: "project/logo.png")
        try host.write(Data("SECRET=2\n".utf8), to: "project/config/.env")
    }

    @Test("變更清單：分支與每個檔案的種類，依路徑排序;從子資料夾讀也是相對 repo 根目錄")
    func statusListsChanges() async throws {
        try makeChanges()

        let status = try await changes.gitStatus(cwd: cwd + "/src")

        #expect(status == GitWorkingTreeStatus(branch: "main", files: [
            GitChange(path: "README.md", kind: .modified),
            GitChange(path: "config/.env", kind: .modified),
            GitChange(path: "gone.txt", kind: .deleted),
            GitChange(path: "logo.png", kind: .modified),
            GitChange(path: "notes/todo.md", kind: .untracked),
            GitChange(path: "src/new.swift", kind: .added),
        ]))
    }

    @Test("全部 diff:hunk 不含檔頭;二進位檔與排除清單不顯示，排除的檔案內容不經過連線")
    func diffOfAllFiles() async throws {
        try makeChanges()

        let diff = try await changes.gitDiff(cwd: cwd, path: nil)

        #expect(diff.truncated == false)
        let byPath = Dictionary(uniqueKeysWithValues: diff.files.map { ($0.path, $0) })
        #expect(byPath["README.md"]?.content == .hunks("@@ -1,3 +1,3 @@\n # Garden\n \n-Water daily.\n+Water twice daily.\n"))
        #expect(byPath["gone.txt"]?.content == .hunks("@@ -1 +0,0 @@\n-old\n"))
        #expect(byPath["src/new.swift"]?.content == .hunks("@@ -0,0 +1 @@\n+let x = 1\n"))
        #expect(byPath["notes/todo.md"]?.content == .hunks("@@ -0,0 +1 @@\n+draft\n"))
        #expect(byPath["logo.png"]?.content == .omitted(.binary))
        #expect(byPath["config/.env"]?.content == .omitted(.excluded))
        #expect(!host.commands.contains { $0.contains(".env") })
    }

    @Test("第一次載入(清單加全部 diff)只跑兩次指令:一次清單、一次 diff")
    func firstLoadRunsTwoCommands() async throws {
        try makeChanges()

        let loaded = try await changes.gitChanges(cwd: cwd)

        #expect(loaded.status.files.count == 6)
        #expect(loaded.diffs.files.count == 6)
        #expect(host.commands.count == 2, "指令數:\(host.commands.count)")
    }

    @Test("排除清單以 repo 根目錄加 git 相對路徑比對:工作目錄在名叫 .ssh 的子資料夾時，別處的檔案不被誤擋")
    func exclusionUsesRepositoryRoot() async throws {
        try makeChanges()
        try host.write(Data("x\n".utf8), to: "project/.ssh/note.txt")

        let diff = try await changes.gitDiff(cwd: cwd + "/.ssh", path: nil)

        let byPath = Dictionary(uniqueKeysWithValues: diff.files.map { ($0.path, $0) })
        #expect(byPath["README.md"]?.content == .hunks("@@ -1,3 +1,3 @@\n # Garden\n \n-Water daily.\n+Water twice daily.\n"))
        // 真的在排除清單裡的路徑(repo 根目錄下的 .ssh)仍然不讀。
        #expect(byPath[".ssh/note.txt"]?.content == .omitted(.excluded))
        #expect(byPath["config/.env"]?.content == .omitted(.excluded))
    }

    @Test("工作目錄已不存在(腳本 exit 66)換成 cwdNotAllowed,不是通用失敗")
    func missingFolderIsReported() async throws {
        await #expect(throws: GitChangesError.cwdNotAllowed) {
            try await changes.gitStatus(cwd: cwd + "/no-such-folder")
        }
    }

    @Test("單檔 diff 只回那個檔案")
    func diffOfOneFile() async throws {
        try makeChanges()

        let diff = try await changes.gitDiff(cwd: cwd, path: "notes/todo.md")

        #expect(diff == GitDiffSet(files: [
            GitFileDiff(path: "notes/todo.md", kind: .untracked, content: .hunks("@@ -0,0 +1 @@\n+draft\n")),
        ], truncated: false))
    }

    @Test("超過單檔上限的 diff 標成過大;總量達上限後的檔案標過大並回報 truncated")
    func largeDiffsAreOmitted() async throws {
        let big = String(repeating: "line of text\n", count: 200)
        try host.write(Data(big.utf8), to: "project/a.txt")
        try host.write(Data(big.utf8), to: "project/b.txt")
        try host.write(Data("x\n".utf8), to: "project/c.txt")

        let perFile = try await SSHGitChanges(channel: host, limits: .init(fileBytes: 1_000, totalBytes: 100_000)).gitDiff(cwd: cwd, path: nil)
        #expect(perFile.files.map(\.content) == [.omitted(.tooLarge), .omitted(.tooLarge), .hunks("@@ -0,0 +1 @@\n+x\n")])
        #expect(perFile.truncated == false)

        let total = try await SSHGitChanges(channel: host, limits: .init(fileBytes: 10_000, totalBytes: 3_000)).gitDiff(cwd: cwd, path: nil)
        #expect(total.files.map(\.path) == ["a.txt", "b.txt", "c.txt"])
        #expect(total.files.dropFirst().map(\.content) == [.omitted(.tooLarge), .omitted(.tooLarge)])
        #expect(total.truncated)
    }

    @Test("不在 git repo 裡丟 notGitRepository;指令帶自我時限")
    func notARepository() async throws {
        let outside = host.url("plain")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        await #expect(throws: GitChangesError.notGitRepository) {
            try await changes.gitStatus(cwd: outside.path(percentEncoded: false))
        }
        #expect(host.commands.allSatisfy { $0.contains(HostScriptTimeLimit.posixMarker) })
    }

    @Test("讀取不改動 repo(不寫 index、不留 lock)")
    func readingLeavesRepositoryUntouched() async throws {
        try makeChanges()
        let index = repo.appending(path: ".git/index")
        let before = try Data(contentsOf: index)

        _ = try await changes.gitStatus(cwd: cwd)
        _ = try await changes.gitDiff(cwd: cwd, path: nil)

        #expect(try Data(contentsOf: index) == before)
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: ".git/index.lock").path(percentEncoded: false)))
    }
}

#endif

/// 跑不了腳本的主機(Windows 主機的通道、Demo 主機不認得的指令)回 unsupported。
@Suite("SSH 主機的 git 變更：不支援的主機")
struct SSHGitChangesUnsupportedTests {
    @Test("Windows 主機不送 POSIX 腳本，回 unsupported")
    func windowsHostIsUnsupported() async throws {
        let host = FakeHost()
        let changes = SSHGitChanges(channel: WindowsHostChannel(host))

        await #expect(throws: GitChangesError.unsupported) { try await changes.gitStatus(cwd: "C:/Users/demo/project") }
        #expect(await host.executions.isEmpty)
    }
}
