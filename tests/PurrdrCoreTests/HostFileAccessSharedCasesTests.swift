import Foundation
import PurrdrCore
import Testing

/// 主機取檔的存取規則與「Agent 寫出的路徑」:與主機服務、SSH 取檔腳本共用 `vendor/purrdr-host/protocol/host-file-access.json` 的案例。
@Suite("主機取檔的存取規則(共用案例)")
struct HostFileAccessSharedCasesTests {
    struct AccessCase: Decodable {
        var name: String
        var platform: String
        var path: String
        var workingDirectory: String?
        var mentioned: Bool
        var expected: String
        var root: String?
        var only: [String]?
    }

    struct MentionCase: Decodable {
        var name: String
        var format: String
        var lines: [String]
        var path: String
        var mentioned: Bool
    }

    struct Environment: Decodable {
        var home: String
        var transcript: String
    }

    struct Vectors: Decodable {
        var environment: [String: Environment]
        var accessCases: [AccessCase]
        var mentionCases: [MentionCase]
    }

    static let vectors: Vectors? = {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: root.appending(path: "vendor/purrdr-host/protocol/host-file-access.json")) else { return nil }
        return try? JSONDecoder().decode(Vectors.self, from: data)
    }()

    @Test("存取案例：工作目錄、家目錄與根目錄、只因提到而放行的位置、排除清單")
    func accessCases() throws {
        let vectors = try #require(Self.vectors)
        let cases = vectors.accessCases.filter { $0.only?.contains("app") ?? true }
        #expect(cases.count >= 20)
        for testCase in cases {
            let environment = try #require(vectors.environment[testCase.platform])
            let scope = HostFileAccessScope(
                workingDirectories: testCase.workingDirectory.map { [$0] } ?? [],
                mentionedPaths: testCase.mentioned ? [testCase.path] : [], transcriptPaths: [environment.transcript])

            let decision = HostFileAccessPolicy.decision(for: testCase.path, in: scope)

            let expected: HostFileAccessPolicy.Decision = testCase.expected == "allowed"
                ? .allowed(HostFileTarget(path: testCase.path, root: testCase.root)) : .denied
            #expect(decision == expected, "\(testCase.name)")
        }
    }

    @Test("提到的路徑：只認 Agent 訊息文字、工具呼叫的檔案路徑、圖片生成與 MCP 圖片;使用者 prompt 與工具結果不算")
    func mentionCases() throws {
        let vectors = try #require(Self.vectors)
        #expect(vectors.mentionCases.count >= 8)
        for testCase in vectors.mentionCases {
            let messages = testCase.lines.flatMap { line in
                testCase.format == "codex" ? CodexTranscriptParser.messages(in: line) : ClaudeTranscriptParser.messages(in: line)
            }

            let mentioned = HostFileAccessScope.mentionedPaths(in: Conversation.items(from: messages))

            #expect(mentioned.contains(testCase.path) == testCase.mentioned, "\(testCase.name):\(mentioned)")
        }
    }
}
