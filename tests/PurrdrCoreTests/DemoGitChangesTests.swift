import PurrdrCore
import PurrdrDemo
import PurrdrSSH
import Testing

/// Demo 主機的變更頁(#310):ledger 的工作目錄走正式的 `SSHGitChanges`,其他 Agent 的資料夾不是 git repo。
@Suite("Demo 主機的變更頁")
struct DemoGitChangesTests {
    @Test("ledger:三個檔案的變更清單與 diff")
    func ledgerHasChanges() async throws {
        let changes = SSHGitChanges(channel: DemoHost())

        let status = try await changes.gitStatus(cwd: "/Users/demo/ledger")
        let diff = try await changes.gitDiff(cwd: "/Users/demo/ledger", path: nil)

        #expect(status.branch == "master")
        #expect(status.files.map(\.kind) == [.deleted, .modified, .added])
        let stats = diff.files.map { file -> GitDiffStats? in
            guard case .hunks(let text) = file.content else { return nil }
            return GitDiffStats(GitDiffLines.parse(text))
        }
        #expect(stats == [GitDiffStats(added: 0, removed: 3), GitDiffStats(added: 3, removed: 1), GitDiffStats(added: 12, removed: 0)])
        guard case .hunks(let csv) = diff.files[1].content else {
            Issue.record("CSVExport.swift 沒有 diff")
            return
        }
        #expect(csv.hasPrefix("@@ -38,7 +38,9 @@"))
    }

    @Test("其他資料夾不是 git repo")
    func otherFoldersAreNotRepositories() async {
        await #expect(throws: GitChangesError.notGitRepository) {
            try await SSHGitChanges(channel: DemoHost()).gitStatus(cwd: "/Users/demo/notes")
        }
    }
}
