#if os(macOS)
import Foundation
import Testing
@testable import PurrdrCore

/// #571:sshd 會先把指令交給使用者的登入 shell(可能是 fish),所以 `PosixShell.quote` 的結果
/// 在 sh、bash、zsh、fish 解析後都必須剛好是原字串。fish 在單引號內把 `\\`、`\'` 當跳脫,
/// 參數含「反斜線＋單引號」就能逃出引號,所以以真的 shell 實跑,並以無害的 `touch` 偵測逃脫。
/// 本機沒有 fish 時只跑其他 shell(`brew install fish` 後才涵蓋 #571)。
struct PosixShellQuotingShellTests {
    static let payloads: [String] = [
        "plain",
        "it's",
        #"a\b"#,
        #"\'; touch ESCAPED; '"#,
        #"x\'$(touch ESCAPED)"#,
        #"\\'; touch ESCAPED; echo '"#,
        #"back\"; touch ESCAPED; echo ""#,
        "`touch ESCAPED`",
        #"\`touch ESCAPED`\"#,
        "$HOME ${HOME} $(touch ESCAPED)",
        #"C:\Users\ray\a b\"#,
        #"trail\"#,
        #"\\"#,
        "semi;colon && pipe | amp & glob * ? [a]",
        "換行\nline2",
        "",
        #"'\"#,
    ]

    private static func shells() -> [String] {
        ["/bin/sh", "/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 以 `<shell> -c <command>` 執行(與 sshd 交給登入 shell 的方式相同),回傳 stdout。
    private static func run(shell: String, command: String, in directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("purrdr-quote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func fishIsAvailable() {
        let hasFish = Self.shells().contains { $0.hasSuffix("fish") }
        if !hasFish { Issue.record("本機沒有 fish,未涵蓋 #571 的回歸(brew install fish)", severity: .warning) }
    }

    @Test(arguments: payloads) func everyShellParsesQuoteBackToTheOriginal(payload: String) throws {
        for shell in Self.shells() {
            let directory = try Self.scratch()
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = try Self.run(shell: shell, command: "printf %s \(PosixShell.quote(payload))", in: directory)
            #expect(String(decoding: output, as: UTF8.self) == payload, "\(shell) 解出的字串不同:\(payload)")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ESCAPED").path), "\(shell) 被逃出引號:\(payload)")
        }
    }

    @Test(arguments: payloads) func everyShellPassesQuotedArgumentsToShDashC(payload: String) throws {
        // 與一次性腳本的形狀相同:/bin/sh -c '<腳本>' name '<參數>'。
        for shell in Self.shells() {
            let directory = try Self.scratch()
            defer { try? FileManager.default.removeItem(at: directory) }
            let command = ["/bin/sh", "-c", PosixShell.quote(#"printf %s "$1""#), "purrdr", PosixShell.quote(payload)].joined(separator: " ")
            let output = try Self.run(shell: shell, command: command, in: directory)
            #expect(String(decoding: output, as: UTF8.self) == payload, "\(shell) 解出的字串不同:\(payload)")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ESCAPED").path), "\(shell) 被逃出引號:\(payload)")
        }
    }

    @Test(arguments: payloads) func unquoteRestoresWhatQuoteProduced(payload: String) {
        #expect(PosixShell.unquote(PosixShell.quote(payload) + " " + PosixShell.quote("x")) == [payload, "x"])
    }
}
#endif
