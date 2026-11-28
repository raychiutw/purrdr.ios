import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing
@testable import PurrdrSSH

/// Agent 設定檔對話紀錄組的契約測試(#439、ADR-0013):對目錄裡每一份方言跑同一組檢查——
/// 用錄製或撰寫的 fixture 解析得出訊息與 metadata、看不懂的行安靜略過、位置規則在每種連線方式都有對應腳本。
@Suite("Agent 設定檔：對話紀錄方言契約")
struct TranscriptDialectContractTests {
    struct FixtureCase: CustomTestStringConvertible, Sendable {
        let dialect: TranscriptDialect
        /// 真實錄製(`true`)或依文件撰寫(`false`,README 標未實測)。
        let isRecording: Bool
        let name: String
        let lines: [String]
        var testDescription: String { "\(dialect.name):\(name)" }
    }

    static let fixtures: [FixtureCase] = [
        FixtureCase(dialect: .claude, isRecording: true, name: "claude-code/session.jsonl", lines: Fixtures.transcriptLines()),
        FixtureCase(dialect: .grok, isRecording: false, name: "grok/updates.jsonl", lines: Fixtures.otherAgentTranscriptLines("grok/updates.jsonl")),
        FixtureCase(
            dialect: .antigravity, isRecording: false, name: "antigravity/transcript.jsonl",
            lines: Fixtures.otherAgentTranscriptLines("antigravity/transcript.jsonl")),
        FixtureCase(
            dialect: .antigravity, isRecording: true, name: "antigravity/live-1.5.14/transcript.jsonl",
            lines: Fixtures.otherAgentTranscriptLines("antigravity/live-1.5.14/transcript.jsonl")),
        FixtureCase(dialect: .piJournal, isRecording: false, name: "pi/session.jsonl", lines: Fixtures.otherAgentTranscriptLines("pi/session.jsonl")),
        FixtureCase(dialect: .codex, isRecording: false, name: "codex/rollout.jsonl", lines: Fixtures.otherAgentTranscriptLines("codex/rollout.jsonl")),
    ]

    @Test("每份方言都有 fixture;標為已驗證的方言必須有真實錄製的 fixture(反之亦然)")
    func everyDialectHasFixtures() {
        for dialect in TranscriptDialect.all {
            let cases = Self.fixtures.filter { $0.dialect == dialect }
            #expect(!cases.isEmpty, "\(dialect.name) 沒有 fixture")
            #expect(cases.contains(where: \.isRecording) == dialect.isVerified, "\(dialect.name) 的驗證狀態與 fixture 來源不符")
        }
    }

    @Test("fixture 解析得出訊息與對話項目", arguments: fixtures)
    func fixtureParses(_ fixture: FixtureCase) {
        let messages = fixture.lines.flatMap(fixture.dialect.messages(in:))

        #expect(!fixture.lines.isEmpty)
        #expect(!messages.isEmpty, "\(fixture.name) 解析不出任何訊息")
        #expect(!Conversation.items(from: messages).isEmpty)
    }

    @Test("fixture 讀得出 header 中繼資料(模型或 context token 數)", arguments: fixtures)
    func fixtureHasMetadata(_ fixture: FixtureCase) {
        let metadata = fixture.dialect.latestMetadata(in: fixture.lines)

        #expect(metadata.model != nil || metadata.contextTokens != nil, "\(fixture.name) 讀不出模型或 token")
    }

    @Test("看不懂的行(被截斷的尾行、不是 JSON)回傳空陣列，不中斷其他行", arguments: fixtures)
    func unparsableLinesAreSkipped(_ fixture: FixtureCase) throws {
        let line = try #require(fixture.lines.first { $0.count > 40 })
        let truncated = String(line.prefix(line.count / 2))

        #expect(fixture.dialect.messages(in: truncated).isEmpty)
        #expect(fixture.dialect.messages(in: "not json").isEmpty)
        #expect(fixture.dialect.messages(in: "").isEmpty)
        var metadata = TranscriptMetadata()
        fixture.dialect.updateMetadata(&metadata, with: truncated)
        #expect(metadata.model == nil && metadata.contextTokens == nil)
    }

    /// 該方言「認不得」的一行(種類是未來才會出現的新種類),內含不該進紀錄的原文。
    static func unknownLine(for dialect: TranscriptDialect) -> String {
        if dialect == .grok {
            return #"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"future_update_9","text":"私密原文"}}}"#
        }
        return #"{"type":"FUTURE_KIND_9","step_index":99,"source":"MODEL","content":"私密原文"}"#
    }

    @Test("混入認不得的行：其他行照常解析、略過的行只記種類與數量(部分失敗,#449)", arguments: fixtures)
    func unknownLinesAreSkippedWithoutFailingTheRest(_ fixture: FixtureCase) {
        let baseline = fixture.dialect.parse(fixture.lines)
        let mixed = [Self.unknownLine(for: fixture.dialect), "{broken json"] + fixture.lines + [Self.unknownLine(for: fixture.dialect), "", "not json at all"]
        let result = fixture.dialect.parse(mixed)

        #expect(result.messages.map(\.id) == baseline.messages.map(\.id))
        #expect(!result.messages.isEmpty)
        let expectedKind = fixture.dialect == .grok ? "future_update_9" : "FUTURE_KIND_9"
        #expect(result.skips.unknownKinds[expectedKind] == 2)
        #expect(result.skips.unparsableLines == baseline.skips.unparsableLines + 2)
        #expect(!"\(result.skips)".contains("私密原文"))
    }

    @Test("真實與撰寫的 fixture 沒有認不得的種類(方言的已知種類清單與資料一致)", arguments: fixtures)
    func fixturesHaveNoUnknownKinds(_ fixture: FixtureCase) {
        #expect(fixture.dialect.parse(fixture.lines).skips.unknownKinds.isEmpty)
    }

    @Test("種類名稱含非 ASCII 或過長時不原樣寫進紀錄")
    func skippedKindNamesAreSanitized() {
        let result = TranscriptDialect.codex.parse([#"{"type":"私密原文"}"#, #"{"type":"\#(String(repeating: "a", count: 90))"}"#])

        #expect(result.skips.unknownKinds["(other)"] == 1)
        #expect(result.skips.unknownKinds[String(repeating: "a", count: 40)] == 1)
    }

    @Test("每份方言的位置規則都登記在全部位置規則裡,且 Windows 與 POSIX 的定位腳本都有對應")
    func locatorsAreRegisteredForEveryHostDialect() {
        let known = TranscriptLocator.all
        let windows = Set(WindowsCommand.transcriptScripts.map(\.posix))
        for dialect in TranscriptDialect.all {
            for locator in [dialect.locator, dialect.reportedPathLocator].compactMap({ $0 }) {
                #expect(known.contains(locator), "\(dialect.name) 的 \(locator.name) 沒有登記")
                #expect(windows.contains(TranscriptCommand.locateScript(locator)), "\(locator.name) 沒有 Windows 版定位腳本")
            }
        }
        #expect(Set(known.map(\.name)).count == known.count, "位置規則名稱重複")
    }

    @Test("每個位置規則的 POSIX 與 PowerShell 片段都進了預覽腳本與 Windows 定位腳本;沿用回報路徑的沒有自己的分支")
    func everyLocatorSnippetIsInGeneratedScripts() throws {
        for locator in TranscriptLocator.all {
            if locator.resolver == "f=$i" {
                #expect(locator.previewBranch == nil && locator.powershellFunction == nil && locator.powershellFindBranch == nil, "\(locator.name)")
                continue
            }
            let previewBranch = try #require(locator.previewBranch, "\(locator.name) 沒有預覽分支")
            let function = try #require(locator.powershellFunction, "\(locator.name) 沒有 PowerShell 函式")
            let findBranch = try #require(locator.powershellFindBranch, "\(locator.name) 沒有 PFind 分支")
            #expect(TranscriptCommand.previewsScript.contains(previewBranch), "\(locator.name)")
            #expect(WindowsScripts.transcriptFunctions.contains(function), "\(locator.name)")
            #expect(WindowsScripts.transcriptFunctions.contains(findBranch), "\(locator.name)")
        }
    }

    @Test("預覽腳本要讀 header 的種類由位置規則的 readsHeader 決定(POSIX 與 PowerShell 同一份名單)")
    func previewHeaderKindsComeFromLocators() {
        let headerKinds = TranscriptLocator.all.filter(\.readsHeader).map(\.name)

        #expect(headerKinds.count >= 2)
        #expect(TranscriptCommand.previewsScript.contains("\(headerKinds.joined(separator: "|")))\nprintf '%s! %s\\n'"))
        #expect(WindowsScripts.previews.contains("if(\(headerKinds.map { "'\($0)'" }.joined(separator: ",")) -ccontains $kind)"))
    }

    @Test("Agent 種類 → 方言:別名統一、認不得的沒有對話紀錄、只有設定檔接受路徑的才收路徑參照")
    func catalogMapsKindsToDialects() throws {
        for (kind, dialect) in [("claude", TranscriptDialect.claude), ("claude-code", .claude), ("codex", .codex), ("grok", .grok), ("grok-build", .grok),
                                ("agy", .antigravity), ("antigravity", .antigravity), ("antigravity-cli", .antigravity), ("pi", .piJournal), ("omp", .piJournal)] {
            #expect(AgentCatalog.profile(forHerdrName: kind).transcript == dialect, "\(kind)")
        }
        for kind in ["opencode", "copilot", "gemini", "future-agent", ""] {
            #expect(AgentCatalog.profile(forHerdrName: kind).transcript == nil, "\(kind)")
        }
        for dialect in TranscriptDialect.all {
            let path = "/home/demo/t.jsonl"
            #expect((dialect.location(kind: "path", value: path, cwd: "/w") != nil) == (dialect.reportedPathLocator != nil), "\(dialect.name)")
            #expect(dialect.location(kind: "id", value: "abc-1", cwd: "/w")?.locator == dialect.locator)
            #expect(dialect.location(kind: "other", value: "x", cwd: "/w") == nil)
        }
    }

    @Test("只有 Claude Code 有 subagent;Claude Code 與 Antigravity 有 session 狀態;slash 選單來源依方言")
    func capabilities() {
        #expect(TranscriptDialect.all.filter(\.supportsSubagents) == [.claude])
        #expect(TranscriptDialect.all.filter(\.readsSessionStatus) == [.claude, .antigravity])
        #expect(TranscriptDialect.claude.slashMenu == .discovered)
        #expect(TranscriptDialect.piJournal.slashMenu == .none)
    }

    @Test("每份方言記錄驗證過(或文件描述)的 Agent 版本")
    func everyDialectRecordsAnAgentVersion() {
        for dialect in TranscriptDialect.all {
            switch dialect.verification {
            case .verified(let version), .unverified(let version): #expect(!version.isEmpty, "\(dialect.name)")
            }
        }
    }
}
