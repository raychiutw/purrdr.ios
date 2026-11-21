import PurrdrCore
import Testing

/// 變更頁(#310):unified diff 的 hunk 拆成有行號的行、+/− 統計，與行內評論組成給 Agent 的訊息。
@Suite("git diff 與行內評論")
struct GitDiffTests {
    /// 主機服務協定範例(`server.git-diff-result.json`)的 README.md diff。
    static let example = "@@ -1,3 +1,3 @@\n # Garden\n \n-Water daily.\n+Water twice daily.\n"

    @Test("hunk 拆成行：標頭、前後文、刪除、新增各帶舊／新行號")
    func parsesHunkIntoNumberedLines() {
        let lines = GitDiffLines.parse(Self.example)

        #expect(lines.map(\.kind) == [.hunkHeader, .context, .context, .removed, .added])
        #expect(lines.map(\.text) == ["@@ -1,3 +1,3 @@", "# Garden", "", "Water daily.", "Water twice daily."])
        #expect(lines.map(\.oldLine) == [nil, 1, 2, 3, nil])
        #expect(lines.map(\.newLine) == [nil, 1, 2, nil, 3])
        #expect(lines.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test("多個 hunk 各自從標頭的起始行號算起;「No newline at end of file」是附註、不占行號")
    func parsesMultipleHunksAndNotes() {
        let diff = "@@ -10,2 +12,3 @@ func field()\n a\n+b\n c\n@@ -40 +43 @@\n-old\n\\ No newline at end of file\n+new\n"
        let lines = GitDiffLines.parse(diff)

        #expect(lines.map(\.kind) == [.hunkHeader, .context, .added, .context, .hunkHeader, .removed, .note, .added])
        #expect(lines.map(\.oldLine) == [nil, 10, nil, 11, nil, 40, nil, nil])
        #expect(lines.map(\.newLine) == [nil, 12, 13, 14, nil, nil, nil, 43])
    }

    @Test("+/− 統計只算新增與刪除的行")
    func countsAddedAndRemovedLines() {
        let stats = GitDiffStats(GitDiffLines.parse("@@ -1,3 +1,4 @@\n a\n-b\n+c\n+d\n e\n"))
        #expect(stats == GitDiffStats(added: 2, removed: 1))
    }

    @Test("評論依檔案在變更清單的順序、行的順序組成一則訊息：路徑:行號、引用那一行(保留 +/−)、評論內容")
    func composesReviewMessage() throws {
        let readme = GitDiffLines.parse(Self.example)
        let swift = GitDiffLines.parse("@@ -40,2 +40,2 @@\n func field() {\n-  return v\n+  guard ok else { return v }\n")
        let comments = [
            GitReviewComment(path: "Sources/CSVExport.swift", line: swift[3], body: "換行 \\r 也要算進去"),
            GitReviewComment(path: "README.md", line: readme[4], body: "  改成一天三次  \n"),
            GitReviewComment(path: "README.md", line: readme[3], body: "這行為什麼刪掉？"),
        ]

        let message = GitReviewMessage.compose(comments, fileOrder: ["README.md", "Sources/CSVExport.swift"])

        #expect(message == """
            README.md:3
            > -Water daily.
            這行為什麼刪掉？

            README.md:3
            > +Water twice daily.
            改成一天三次

            Sources/CSVExport.swift:41
            > +  guard ok else { return v }
            換行 \\r 也要算進去
            """)
    }

    @Test("空白評論不組進訊息")
    func blankCommentsAreSkipped() {
        let line = GitDiffLines.parse(Self.example)[4]
        #expect(GitReviewMessage.compose([GitReviewComment(path: "README.md", line: line, body: " \n ")], fileOrder: ["README.md"]).isEmpty)
    }
}
