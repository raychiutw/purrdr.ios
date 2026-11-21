import Foundation
import PurrdrCore
import PurrdrSSH

/// Demo 主機的變更頁(#310):ledger 的工作目錄是 git repo,改了 CSV 匯出、加了測試、刪了一個範例檔;其他資料夾不是 repo。
/// 回應 `GitChangesCommand` 的指令(走正式的 `SSHGitChanges`)。
enum DemoGitChanges {
    static let repository = "/Users/demo/ledger"

    static let status = GitWorkingTreeStatus(branch: "master", files: [
        GitChange(path: "Fixtures/draft.csv", kind: .deleted),
        GitChange(path: "Sources/CSVExport.swift", kind: .modified),
        GitChange(path: "Tests/CSVQuotingTests.swift", kind: .added),
    ])

    /// 每個檔案的 `git diff` 輸出(含檔頭，像真的主機)。
    static let diffs: [String: String] = [
        "Sources/CSVExport.swift": """
            diff --git a/Sources/CSVExport.swift b/Sources/CSVExport.swift
            index 3f1c2aa..8b0d4e1 100644
            --- a/Sources/CSVExport.swift
            +++ b/Sources/CSVExport.swift
            @@ -38,7 +38,9 @@ struct CSVExport {
                 }

                 func field(_ value: String) -> String {
            -        return value
            +        let needsQuote: (Character) -> Bool = { $0 == "," || $0 == "\\"" || $0 == "\\n" }
            +        guard value.contains(where: needsQuote) else { return value }
            +        return "\\"" + value.replacing("\\"", with: "\\"\\"") + "\\""
                 }

                 func row(_ values: [String]) -> String {

            """,
        "Tests/CSVQuotingTests.swift": """
            diff --git a/Tests/CSVQuotingTests.swift b/Tests/CSVQuotingTests.swift
            new file mode 100644
            index 0000000..5d2c9f0
            --- /dev/null
            +++ b/Tests/CSVQuotingTests.swift
            @@ -0,0 +1,12 @@
            +import Testing
            +@testable import Ledger
            +
            +struct CSVQuotingTests {
            +    @Test func plainFieldIsUnchanged() {
            +        #expect(CSVExport().field("coffee") == "coffee")
            +    }
            +
            +    @Test func commaIsQuoted() {
            +        #expect(CSVExport().field("tea, milk") == "\\"tea, milk\\"")
            +    }
            +}

            """,
        "Fixtures/draft.csv": """
            diff --git a/Fixtures/draft.csv b/Fixtures/draft.csv
            deleted file mode 100644
            index 7a1e0b3..0000000
            --- a/Fixtures/draft.csv
            +++ /dev/null
            @@ -1,3 +0,0 @@
            -date,item,amount
            -2026-11-02,coffee,3.20
            -2026-11-03,bus,1.80

            """,
    ]

    /// `GitChangesCommand` 的指令才回應;其他指令回 `nil`。
    static func respond(to command: String) -> (stdout: Data, exitCode: Int32)? {
        guard let request = GitChangesCommand.request(in: command) else { return nil }
        switch request {
        case .status(let cwd):
            guard isInRepository(cwd) else { return (Data(), 65) }
            return (GitChangesCommand.statusOutput(status), 0)
        case .diff(let cwd, let marker, let files):
            guard isInRepository(cwd) else { return (Data(), 65) }
            return (GitChangesCommand.diffOutput(marker: marker, diffs: files.map { diffs[$0.path] ?? "" }), 0)
        }
    }

    private static func isInRepository(_ cwd: String) -> Bool {
        cwd == repository || cwd.hasPrefix(repository + "/")
    }
}
