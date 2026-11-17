import Foundation
import PurrdrCore

/// 在主機上發現 Claude Code 的 slash 清單(#15、行為規格 F9.1–F9.2)。
///
/// 資料來源:
/// - session 對話紀錄中 Claude Code 寫入的 `skill_listing`(attachment)。它只列**模型可呼叫**的 skill,
///   `disable-model-invocation: true` 的(例如 `/implement`、`/to-spec`)和 plugin 的 `commands/` 都不在裡面，
///   所以不能只靠它：一律再掃主機，兩邊合併(同名以出處較明確的為準，說明互補)。
/// - 主機上的 `~/.claude/plugins/installed_plugins.json` → 每個 plugin 的 `.claude-plugin/plugin.json`
///   宣告的 `skills`、`commands` 路徑(**宣告了就只用宣告的**,沒宣告才用預設 `skills/`、`commands/`);
///   `settings.json` 的 `enabledPlugins` 為 `false` 的 plugin 不列;使用者層與專案層 `.claude/skills`、`.claude/commands`。
/// - 內建指令(`ClaudeBuiltinCommands`)。
///
/// 只設**時間上限**:到時還沒做完就回傳已讀到的部分並標示 `isComplete == false`。
public struct ClaudeSlashDiscovery: SlashDiscovering {
    private let channel: any HostChannel
    private let timeLimit: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        channel: any HostChannel, timeLimit: Duration = .seconds(20),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.channel = channel
        self.timeLimit = timeLimit
        self.sleep = sleep
    }

    /// - Parameters:
    ///   - cwd: agent 的工作資料夾(專案層 skills／commands、專案層 plugin 與設定)。
    ///   - transcriptPath: session 的對話紀錄(讀 `skill_listing`)。
    public func catalog(cwd: String?, transcriptPath: String?) async -> SlashCatalog {
        let progress = Progress()
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.discover(cwd: cwd, transcriptPath: transcriptPath, into: progress) }
            group.addTask {
                try? await sleep(timeLimit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return await progress.catalog(isComplete: finished)
    }

    // MARK: - 步驟

    /// 三步依序執行;任何一步失敗就停(已讀到的保留)。全部成功回傳 true。
    private func discover(cwd: String?, transcriptPath: String?, into progress: Progress) async -> Bool {
        guard let first = await run(ClaudeSlashCommand.discover(cwd: cwd, transcriptPath: transcriptPath)) else { return false }
        let records = Self.records(in: first)
        let state = DiscoveryState(records: records, cwd: cwd)
        await progress.add(state.ownEntries + state.listingEntries)
        let plugins = state.enabledInstalls
        guard !plugins.isEmpty else { return true }

        guard let second = await run(ClaudeSlashCommand.manifests(installPaths: plugins.map(\.installPath))) else { return false }
        var manifests: [String: [String: Any]] = [:]
        for record in Self.records(in: second) where record.kind == "F" {
            if let object = (try? JSONSerialization.jsonObject(with: Data(record.text.utf8))) as? [String: Any] {
                manifests[record.fields[0]] = object
            }
        }
        let scans = plugins.flatMap { install in
            Self.scans(for: install, manifest: manifests[install.installPath])
        }
        guard !scans.isEmpty else { return true }
        guard let third = await run(ClaudeSlashCommand.scan(scans)) else { return false }
        await progress.add(Self.records(in: third).compactMap { Self.entry(from: $0, plugin: true) })
        return true
    }

    /// plugin 要掃的路徑：`plugin.json` 的 `skills`、`commands` 宣告(字串或陣列)取代預設的 `skills/`、`commands/`。
    static func scans(for install: PluginInstall, manifest: [String: Any]?) -> [ClaudeSlashCommand.Scan] {
        let name = (manifest?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? install.fallbackName
        func paths(_ key: String, default value: String) -> [String] {
            let declared: [String] = switch manifest?[key] {
            case let single as String: [single]
            case let many as [Any]: many.compactMap { $0 as? String }
            default: []
            }
            return (declared.isEmpty ? [value] : declared).compactMap { resolve($0, in: install.installPath) }
        }
        return paths("skills", default: "skills").map { .init(kind: .skills, plugin: name, path: $0) }
            + paths("commands", default: "commands").map { .init(kind: .commands, plugin: name, path: $0) }
    }

    /// plugin 內的相對路徑(`./skills/x`)→ 絕對路徑。跳出 plugin 資料夾(`..`)的不接受。
    /// Windows 的 installPath(`C:\…`)後面一樣接 `/…`(PowerShell 兩種分隔符號都認)。
    static func resolve(_ path: String, in root: String) -> String? {
        let parts = path.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
        guard !parts.contains("..") else { return nil }
        let base = HostPathSyntax.trimmingTrailingSeparator(root)
        return parts.isEmpty ? base : base + "/" + parts.joined(separator: "/")
    }

    /// 執行並收集 stdout;exit code 不是 0、通道失敗、逾時(每個指令的期限同時間上限)或被取消 → nil。
    private func run(_ command: String) async -> String? {
        let output = try? await channel.runOnce(command, deadline: timeLimit, sleep: sleep) { session in
            var stdout = Data()
            var exitCode: Int32?
            for try await event in session.output {
                switch event {
                case .stdout(let data): stdout.append(data)
                case .stderr: break
                case .exit(let code, _): exitCode = code
                }
            }
            return (stdout, exitCode)
        }
        guard let (stdout, exitCode) = output, exitCode == 0, !Task.isCancelled else { return nil }
        return String(decoding: stdout, as: UTF8.self)
    }

    // MARK: - 輸出解析

    struct Record {
        /// `F`、`S`、`L`。
        var kind: String
        var fields: [String]
        var lines: [String]
        var text: String { lines.joined(separator: "\n") }
    }

    static func records(in output: String) -> [Record] {
        var records: [Record] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@") {
                let fields = line.dropFirst().split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                records.append(Record(kind: fields.first ?? "", fields: Array(fields.dropFirst()), lines: []))
            } else if line.hasPrefix("|"), !records.isEmpty {
                records[records.count - 1].lines.append(String(line.dropFirst()))
            }
        }
        return records
    }

    /// `@S` 紀錄 → 一個指令。skill 名稱取 frontmatter 的 `name`(沒有時用資料夾名);指令名稱是相對基準資料夾的路徑，
    /// `/` 換成 `:`(`foo/bar.md` → `foo:bar`);plugin 的加上 `<plugin>:`。`user-invocable: false` 的不列。
    static func entry(from record: Record, plugin: Bool) -> (source: SlashSource, command: SlashCommand)? {
        guard record.kind == "S", record.fields.count >= 3 else { return nil }
        let tag = record.fields[0]
        let base = record.fields[1]
        let path = record.fields[2]
        let meta = ClaudeFrontmatter.parse(record.lines)
        if meta["user-invocable"]?.lowercased() == "false" { return nil }
        let localName: String
        if path.hasSuffix("/SKILL.md") {
            let folder = String(path.dropLast("/SKILL.md".count))
            let folderName = folder.split(separator: "/").last.map(String.init) ?? ""
            localName = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folderName
        } else {
            guard path.hasSuffix(".md"), path.hasPrefix(base + "/") else { return nil }
            localName = String(path.dropFirst(base.count + 1).dropLast(3)).replacingOccurrences(of: "/", with: ":")
        }
        guard !localName.isEmpty, localName.wholeMatch(of: /[\w:.-]+/) != nil else { return nil }
        let source: SlashSource
        let name: String
        if plugin {
            source = .plugin(tag)
            name = tag + ":" + localName
        } else {
            source = tag == "project" ? .project : .user
            name = localName
        }
        let hint = meta["argument-hint"].flatMap { $0.isEmpty ? nil : $0 }
        return (source, SlashCommand(name: name, argumentHint: hint, summary: meta["description"] ?? ""))
    }
}

/// 一個已安裝 plugin 的位置(`installed_plugins.json` 的一筆)。
struct PluginInstall: Sendable, Equatable {
    /// `<名稱>@<marketplace>`。
    var key: String
    var installPath: String

    /// 沒有 `plugin.json` 時的名稱。
    var fallbackName: String { String(key.split(separator: "@").first ?? Substring(key)) }
}

/// 第 1 步的結果。
struct DiscoveryState {
    var records: [ClaudeSlashDiscovery.Record]
    var cwd: String?

    private func file(_ tag: String) -> [String: Any]? {
        guard let record = records.first(where: { $0.kind == "F" && $0.fields.first == tag }) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(record.text.utf8))) as? [String: Any]
    }

    /// 使用者層與專案層的 skills／commands。
    var ownEntries: [(source: SlashSource, command: SlashCommand)] {
        records.compactMap { ClaudeSlashDiscovery.entry(from: $0, plugin: false) }
    }

    /// 要用的 plugin:`enabledPlugins` 沒設成 `false`(專案層設定蓋過使用者層),
    /// 且這一筆安裝適用於這個資料夾(使用者層，或專案層且 `projectPath` 等於 cwd;專案層優先)。
    var enabledInstalls: [PluginInstall] {
        guard let installed = file("installed")?["plugins"] as? [String: Any] else { return [] }
        var enabled: [String: Bool] = [:]
        for tag in ["settings", "project-settings", "local-settings"] {
            for (key, value) in (file(tag)?["enabledPlugins"] as? [String: Any]) ?? [:] {
                if let flag = value as? Bool { enabled[key] = flag }
            }
        }
        return installed.keys.sorted().compactMap { key in
            guard enabled[key] != false else { return nil }
            let entries: [[String: Any]] = switch installed[key] {
            case let many as [[String: Any]]: many
            case let one as [String: Any]: [one]
            default: []
            }
            let projectEntry = entries.first { entry in
                guard let project = entry["projectPath"] as? String, let cwd else { return false }
                return Self.samePath(project, cwd)
            }
            let userEntry = entries.first { $0["projectPath"] == nil }
            guard let path = (projectEntry ?? userEntry)?["installPath"] as? String, HostPathSyntax.isAbsolute(path) else { return nil }
            return PluginInstall(key: key, installPath: path)
        }
    }

    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        HostPathSyntax.trimmingTrailingSeparator(lhs) == HostPathSyntax.trimmingTrailingSeparator(rhs)
    }

    /// 對話紀錄中最後一次完整的 `skill_listing`(`isInitial`)加上之後的增量。名稱有 `<plugin>:` 的歸到該 plugin,
    /// 其他的歸到「其他」(若主機上找得到同名的使用者／專案 skill,合併時以那邊為準)。
    var listingEntries: [(source: SlashSource, command: SlashCommand)] {
        guard let listing = records.first(where: { $0.kind == "L" }) else { return [] }
        let attachments = listing.lines.compactMap { line -> [String: Any]? in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let attachment = object["attachment"] as? [String: Any], attachment["type"] as? String == "skill_listing" else { return nil }
            return attachment
        }
        let start = attachments.lastIndex { ($0["isInitial"] as? Bool) == true } ?? 0
        var result: [(SlashSource, SlashCommand)] = []
        var seen = Set<String>()
        for attachment in attachments[start...] {
            let summaries = Self.summaries(in: attachment["content"] as? String ?? "")
            for name in (attachment["names"] as? [String]) ?? [] where seen.insert(name).inserted {
                guard name.wholeMatch(of: /[\w:.-]+/) != nil else { continue }
                let parts = name.split(separator: ":", maxSplits: 1)
                let source: SlashSource = parts.count == 2 ? .plugin(String(parts[0])) : .session
                result.append((source, SlashCommand(name: name, summary: summaries[name] ?? "")))
            }
        }
        return result
    }

    /// `- 名稱: 說明` 的清單。
    static func summaries(in content: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in content.split(separator: "\n") where line.hasPrefix("- ") {
            guard let colon = line.firstRange(of: ": ") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 2)..<colon.lowerBound])
            result[name] = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}

/// 發現中逐步累積的結果(逾時時回傳已有的部分)。
private actor Progress {
    private var entries: [(source: SlashSource, command: SlashCommand)] = ClaudeBuiltinCommands.all.map { (.builtIn, $0) }

    func add(_ more: [(source: SlashSource, command: SlashCommand)]) {
        entries += more
    }

    func catalog(isComplete: Bool) -> SlashCatalog {
        SlashCatalog.merged(entries, isComplete: isComplete)
    }
}

/// SKILL.md／指令 .md 的 YAML frontmatter(只取頂層的字串欄位)。
///
/// 支援：引號字串、block scalar(`>`、`>-`、`|`、`|-`…)、跨行的 plain scalar。不是完整的 YAML。
public enum ClaudeFrontmatter {
    public static func parse(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let first = line.first, first != " ", first != "\t", first != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var continuation: [String] = []
            while index < lines.count, lines[index].isEmpty || lines[index].first == " " || lines[index].first == "\t" {
                continuation.append(lines[index])
                index += 1
            }
            let trimmedContinuation = continuation.map { $0.trimmingCharacters(in: .whitespaces) }
            if let indicator = raw.first, indicator == ">" || indicator == "|", raw.count <= 3 {
                let body = trimmedContinuation.reversed().drop { $0.isEmpty }.reversed()
                result[key] = indicator == ">"
                    ? body.split(separator: "").map { $0.joined(separator: " ") }.joined(separator: "\n")
                    : body.joined(separator: "\n")
            } else if raw.hasPrefix("\"") {
                let joined = ([raw] + trimmedContinuation.filter { !$0.isEmpty }).joined(separator: " ")
                result[key] = unquoteDouble(joined)
            } else if raw.hasPrefix("'") {
                let joined = ([raw] + trimmedContinuation.filter { !$0.isEmpty }).joined(separator: " ")
                var inner = joined.dropFirst()
                if inner.hasSuffix("'") { inner = inner.dropLast() }
                result[key] = inner.replacingOccurrences(of: "''", with: "'")
            } else {
                result[key] = ([raw] + trimmedContinuation.filter { !$0.isEmpty }).filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        return result
    }

    private static func unquoteDouble(_ text: String) -> String {
        var inner = text.dropFirst()
        if inner.hasSuffix("\""), !inner.hasSuffix("\\\"") || inner.hasSuffix("\\\\\"") { inner = inner.dropLast() }
        var output = ""
        var escaping = false
        for character in inner {
            if escaping {
                switch character {
                case "n": output.append("\n")
                case "t": output.append("\t")
                default: output.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                output.append(character)
            }
        }
        return output
    }
}
