import Foundation
import PurrdrCore
import Testing

/// Agent 種類字串比對的守門(#444、ADR-0013)。
///
/// herdr 回報的 `agent` 字串只在 `AgentID(herdrName:)` 轉成種類;之後一律比對 `AgentID` 或問 `AgentCatalog` 的設定檔。
/// 這個測試掃 `src/` 全部原始碼:出現「拿 Agent 名稱字面值做比較」(`== "claude"`、`case "codex"`…)就失敗,
/// 另外掃「寫在 Swift 字串裡的 shell 腳本」的 `claude)`／`pi|codex)` 這類 case 分支(#549):
/// 腳本是主機端的協定,種類字串無法在腳本裡問 `AgentCatalog`,所以逐一列在 `allowedShellCases` 並說明理由。
/// **續接參數**(`SSHResumeRequests` 的 `--resume <id>`／`resume <id>`)是 Agent CLI 自己的語法,
/// 以 `AgentID` 的 `switch` 分派、不比對字串,所以不在掃描範圍;它是已知的寫死處,與主機服務(Rust)的做法一致,
/// 要新增能續接的 Agent 時在那裡加 case(`resumeKind` 設定檔欄位已限制哪些種類能走到)。
/// 白名單只有設定檔本身(`AgentProfile.swift`,別名表與設定檔都在那裡)與 schema 產生的協定型別。
@Suite("Agent 字串比對守門")
struct AgentStringGuardTests {
    /// 設定檔本身:`AgentID` 的名稱表與目錄。
    static let allowedFiles: Set<String> = ["AgentProfile.swift", "HostServiceProtocol.swift"]

    /// 字面值剛好是 Agent 名稱、但不是 Agent 種類的少數地方(連同理由)。新增前先確認真的不是 Agent 種類。
    static let allowedLines: [(file: String, literal: String, reason: String)] = [
        ("WindowsErrorText.swift", "amp", "XML 實體 `&amp;`,不是 amp 這個 Agent"),
    ]

    /// 寫在 Swift 字串裡的 shell 腳本中,以 Agent 種類分流的 case 分支(連同理由)。新增前先確認腳本真的需要分流。
    static let allowedShellCases: [(file: String, literal: String, reason: String)] = [
        ("TranscriptCommand.swift", "claude", "對話紀錄腳本依種類分流找檔;種類值由呼叫端以參數傳入"),
        ("TranscriptCommand.swift", "codex", "同上"),
        ("TranscriptCommand.swift", "grok", "同上"),
        ("TranscriptCommand.swift", "agy", "同上"),
        ("TranscriptCommand.swift", "pi", "同上"),
        ("SSHSessionHistory.swift", "claude", "session 清單腳本依種類找資料夾(參數是 `resumeKind` 的正式名稱)"),
        ("SSHSessionHistory.swift", "codex", "同上"),
    ]

    /// 要擋的名稱:herdr 的正式名稱、別名與舊版誤用拼法。
    static let names: [String] = {
        let aliases = ["claude-code", "antigravity", "antigravity-cli", "open_code", "open-code", "github_copilot", "github-copilot"]
        return Set(AgentID.allCases.map(\.canonicalName) + aliases).sorted()
    }()

    static var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var sourceFiles: [URL] {
        FileManager.default.enumerator(at: repositoryRoot.appending(path: "src"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    }

    /// 找出一份原始碼裡的 Agent 名稱比對(略過整行註解)。回傳 (行號, 名稱)。
    static func violations(inSource source: String) -> [(line: Int, literal: String)] {
        let alternatives = names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let comparison = try? NSRegularExpression(pattern: "(?:(?:==|!=)\\s*\"(\(alternatives))\"|\"(\(alternatives))\"\\s*(?:==|!=))")
        let literal = try? NSRegularExpression(pattern: "\"(\(alternatives))\"")
        var found: [(line: Int, literal: String)] = []
        for (index, text) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = text.drop(while: { $0 == " " })
            if trimmed.hasPrefix("//") { continue }
            let line = String(text)
            for match in comparison?.matches(in: line, range: NSRange(line.startIndex..., in: line)) ?? [] {
                for group in 1...2 {
                    if let range = Range(match.range(at: group), in: line) { found.append((index + 1, String(line[range]))) }
                }
            }
            // `case "grok", "agy":`:冒號之前的每個字面值都算。
            if trimmed.hasPrefix("case \""), let colon = line.firstIndex(of: ":") {
                let head = String(line[..<colon])
                for match in literal?.matches(in: head, range: NSRange(head.startIndex..., in: head)) ?? [] {
                    if let range = Range(match.range(at: 1), in: head) { found.append((index + 1, String(head[range]))) }
                }
            }
        }
        return found
    }

    @Test("核心以外沒有直接比對 Agent 名稱的程式碼")
    func noAgentNameComparisonsOutsideProfiles() throws {
        let files = Self.sourceFiles
        #expect(files.count > 100, "沒有掃到原始碼，路徑可能錯了")
        var problems: [String] = []
        for file in files where !Self.allowedFiles.contains(file.lastPathComponent) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for hit in Self.violations(inSource: source) {
                if Self.allowedLines.contains(where: { $0.file == file.lastPathComponent && $0.literal == hit.literal }) { continue }
                problems.append("\(file.lastPathComponent):\(hit.line) 比對 \"\(hit.literal)\"(請改用 AgentID／AgentCatalog)")
            }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    /// 找出 shell `case` 分支(`claude)`、`pi|pipath|codex)`)裡的 Agent 名稱。
    static func shellCaseViolations(inSource source: String) -> [(line: Int, literal: String)] {
        let alternatives = names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let pattern = try? NSRegularExpression(pattern: "^\\s*((?:[A-Za-z0-9_-]+\\|)*(?:[A-Za-z0-9_-]+))\\)\\s*(?:;;.*|[^\\s].*)?$"),
              let name = try? NSRegularExpression(pattern: "^(?:\(alternatives))$") else { return [] }
        var found: [(line: Int, literal: String)] = []
        for (index, text) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(text)
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            for part in line[range].split(separator: "|") where name.firstMatch(in: String(part), range: NSRange(location: 0, length: part.utf16.count)) != nil {
                found.append((index + 1, String(part)))
            }
        }
        return found
    }

    @Test("字串裡的 shell 腳本沒有未登記的 Agent 種類分支")
    func noUnlistedShellCases() throws {
        var problems: [String] = []
        for file in Self.sourceFiles where !Self.allowedFiles.contains(file.lastPathComponent) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for hit in Self.shellCaseViolations(inSource: source) {
                if Self.allowedShellCases.contains(where: { $0.file == file.lastPathComponent && $0.literal == hit.literal }) { continue }
                problems.append("\(file.lastPathComponent):\(hit.line) shell case \"\(hit.literal)\"(請改用參數傳入,或登記進 allowedShellCases 並寫理由)")
            }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test("shell case 掃描器抓得到單一與多個種類,不誤判其他分支")
    func shellScannerRecognizesPatterns() {
        let source = """
        case $t in
        claude)
        @X@
        ;;
        pi|pipath|codex)
        echo
        ;;
        whole)
        *)
        esac
        """
        let hits = Self.shellCaseViolations(inSource: source).map { "\($0.line):\($0.literal)" }
        #expect(hits == ["2:claude", "5:pi", "5:codex"], "\(hits)")
    }

    @Test("掃描器抓得到各種比對寫法，不誤判註解與一般字串")
    func scannerRecognizesPatterns() {
        let source = """
        if kind == "claude" { }
        if "codex" != agent { }
        switch kind {
        case "grok", "agy": break
        case .claude: break
        }
        // kind == "claude" 在註解裡不算
        let titles = ["claude code", "claude"]
        let id = AgentID(herdrName: "claude")
        guard agentKind != "antigravity" else { return }
        """
        let hits = Self.violations(inSource: source).map { "\($0.line):\($0.literal)" }
        #expect(hits.sorted() == ["1:claude", "10:antigravity", "2:codex", "4:agy", "4:grok"].sorted(), "\(hits)")
    }

    @Test("AgentKind 已退場:程式碼不再出現(註解與文件不算)")
    func agentKindIsRetired() throws {
        let pattern = try Regex("\\bAgentKind\\b")
        for file in Self.sourceFiles where file.lastPathComponent != "HostServiceProtocol.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                #expect(code.firstMatch(of: pattern) == nil, "\(file.lastPathComponent):\(index + 1) 還在用 AgentKind,改用 AgentID")
            }
        }
    }

    @Test("舊的 AgentKindName 已刪除")
    func agentKindNameIsGone() throws {
        for file in Self.sourceFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("AgentKindName"), "\(file.lastPathComponent) 還在用 AgentKindName")
        }
    }

    @Test("目錄裡每一份設定檔:id 對得上、顯示組齊全、能開新聊天的種類有 session 組")
    func everyProfileIsConsistent() {
        for id in AgentID.allCases {
            let profile = AgentCatalog.profile(for: id)
            #expect(profile.id == id)
            #expect(profile.presentation.displayName?.isEmpty == false, "\(id.canonicalName) 沒有顯示名稱")
            #expect(AgentID(herdrName: id.canonicalName) == id)
        }
        for id in AgentCatalog.startableAgents {
            #expect(AgentID.allCases.contains(id))
            #expect(AgentCatalog.profile(for: id).session.startsNewChat, "\(id.canonicalName) 不能開新聊天")
        }
    }
}
