import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 變更頁(#310):變更清單(種類、+/−)→ 單檔 diff,在行上寫評論，最後組成一則訊息。
@MainActor
@Suite("變更頁")
struct ChangesModelTests {
    static let cwd = "/Users/demo/Projects/ledger"
    static let csv = "@@ -40,2 +40,3 @@\n func field() {\n-  return v\n+  guard ok else { return v }\n+  return quoted(v)\n"
    static let readme = "@@ -1,3 +1,3 @@\n # Ledger\n \n-Old.\n+New.\n"

    static let status = GitWorkingTreeStatus(branch: "master", files: [
        GitChange(path: "README.md", kind: .modified),
        GitChange(path: "Sources/CSVExport.swift", kind: .modified),
        GitChange(path: "logo.png", kind: .added),
        GitChange(path: "big.json", kind: .untracked),
    ])
    static let diffs = GitDiffSet(files: [
        GitFileDiff(path: "README.md", kind: .modified, content: .hunks(readme)),
        GitFileDiff(path: "Sources/CSVExport.swift", kind: .modified, content: .hunks(csv)),
        GitFileDiff(path: "logo.png", kind: .added, content: .omitted(.binary)),
        GitFileDiff(path: "big.json", kind: .untracked, content: .omitted(.tooLarge)),
    ], truncated: true)

    static func model(_ reader: FakeGitChanges, canSend: Bool = true) -> ChangesModel {
        ChangesModel(reader: reader, cwd: cwd, canSend: { canSend })
    }

    @Test("讀變更清單：分支、每個檔案的種類與 +/−;不顯示 diff 的檔案沒有行數")
    func loadsChangedFiles() async {
        let reader = FakeGitChanges(status: Self.status, diffs: Self.diffs)
        let model = Self.model(reader)

        await model.load()

        #expect(model.phase == .loaded)
        #expect(model.branch == "master")
        #expect(model.files.map(\.path) == ["README.md", "Sources/CSVExport.swift", "logo.png", "big.json"])
        #expect(model.files.map(\.kind) == [.modified, .modified, .added, .untracked])
        #expect(model.files.map(\.stats) == [GitDiffStats(added: 1, removed: 1), GitDiffStats(added: 2, removed: 1), nil, nil])
        #expect(await reader.requests == [.status(cwd: Self.cwd), .diff(cwd: Self.cwd, path: nil)])
    }

    @Test("第一次載入固定先讀清單、再讀 diff(不並行,請求順序是確定的);清單失敗就不讀 diff")
    func loadReadsStatusThenDiffDeterministically() async {
        for _ in 0..<300 {
            let reader = FakeGitChanges(status: Self.status, diffs: Self.diffs)
            await Self.model(reader).load()
            #expect(await reader.requests == [.status(cwd: Self.cwd), .diff(cwd: Self.cwd, path: nil)])
        }
        let failing = FakeGitChanges(failing: GitChangesError.notGitRepository)
        await Self.model(failing).load()
        #expect(await failing.requests == [.status(cwd: Self.cwd)])
    }

    @Test("單檔 diff:已讀過的直接用;二進位顯示原因;總量截斷而過大的檔案單獨再讀一次")
    func fileDiffs() async {
        let reader = FakeGitChanges(status: Self.status, diffs: Self.diffs)
        await reader.setFileDiff(GitDiffSet(files: [
            GitFileDiff(path: "big.json", kind: .untracked, content: .hunks("@@ -0,0 +1 @@\n+{}\n")),
        ], truncated: false), for: "big.json")
        let model = Self.model(reader)
        await model.load()

        await model.loadDiff(of: "Sources/CSVExport.swift")
        await model.loadDiff(of: "logo.png")
        await model.loadDiff(of: "big.json")

        #expect(model.diff(of: "Sources/CSVExport.swift") == .lines(GitDiffLines.parse(Self.csv)))
        #expect(model.diff(of: "logo.png") == .omitted(.binary))
        #expect(model.diff(of: "big.json") == .lines(GitDiffLines.parse("@@ -0,0 +1 @@\n+{}\n")))
        #expect(await reader.requests.last == .diff(cwd: Self.cwd, path: "big.json"))
        #expect(await reader.requests.count == 3)
    }

    @Test("讀取失敗依原因說明：不是 git repo、Agent 換了資料夾、要更新主機服務、不支援", arguments: [
        (GitChangesError.notGitRepository as any Error & Sendable, ChangesProblem.notGitRepository),
        (GitChangesError.cwdNotAllowed, .agentMoved),
        (GitChangesError.unsupported, .unsupported),
        (GitChangesError.gitNotInstalled, .gitNotInstalled),
        (HostServiceError.hostServiceUpdateRequired(.gitChanges, installedVersion: "0.6.0"), .hostServiceUpdateRequired(installedVersion: "0.6.0")),
        (HostServiceError.connectionLost, .failed),
    ])
    func failures(_ error: any Error & Sendable, _ problem: ChangesProblem) async {
        let model = Self.model(FakeGitChanges(failing: error))
        await model.load()
        #expect(model.phase == .failed(problem))
    }

    @Test("在行上寫評論：同一行再寫是改寫，清空是刪除;只算有內容的行")
    func commentsOnLines() async throws {
        let model = Self.model(FakeGitChanges(status: Self.status, diffs: Self.diffs))
        await model.load()
        let lines = GitDiffLines.parse(Self.csv)

        model.setComment("先寫", on: lines[3], in: "Sources/CSVExport.swift")
        model.setComment("換行也要算", on: lines[3], in: "Sources/CSVExport.swift")
        model.setComment("為什麼刪", on: lines[2], in: "Sources/CSVExport.swift")
        model.setComment("標頭不能評", on: lines[0], in: "Sources/CSVExport.swift")
        #expect(model.comments.count == 2)
        #expect(model.comment(on: lines[3], in: "Sources/CSVExport.swift")?.body == "換行也要算")

        model.setComment("  ", on: lines[2], in: "Sources/CSVExport.swift")
        model.setComment("改成 New", on: GitDiffLines.parse(Self.readme)[4], in: "README.md")

        #expect(model.comments.count == 2)
        #expect(model.commentedFileCount == 2)
    }

    @Test("送出評論：依變更清單的檔案順序組成一則訊息，送出後清空")
    func takeReviewComposesMessage() async throws {
        let model = Self.model(FakeGitChanges(status: Self.status, diffs: Self.diffs))
        await model.load()
        model.setComment("換行也要算", on: GitDiffLines.parse(Self.csv)[3], in: "Sources/CSVExport.swift")
        model.setComment("改成 New", on: GitDiffLines.parse(Self.readme)[4], in: "README.md")

        let message = model.takeReview()

        #expect(message == "README.md:3\n> +New.\n改成 New\n\nSources/CSVExport.swift:41\n> +  guard ok else { return v }\n換行也要算")
        #expect(model.comments.isEmpty)
        #expect(model.takeReview() == nil)
    }

    @Test("唯讀裝置或聊天不能送出時：可以看 diff,不能送出評論")
    func cannotSendWhenChatCannot() async {
        let model = Self.model(FakeGitChanges(status: Self.status, diffs: Self.diffs), canSend: false)
        await model.load()
        model.setComment("改成 New", on: GitDiffLines.parse(Self.readme)[4], in: "README.md")

        #expect(model.phase == .loaded)
        #expect(!model.canSendReview)
        #expect(model.takeReview() == nil)
        #expect(model.comments.count == 1)
    }
}
