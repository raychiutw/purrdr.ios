import Foundation
import PurrdrCore

public enum AntigravityUsageError: Error, Equatable {
    /// `~/.gemini/antigravity-cli/settings.json` 不是合法 JSON 物件,不能安全地修改。
    case settingsNotJSON
    /// 主機上沒有 `~/.gemini/antigravity-cli`(沒裝 Antigravity)。
    case antigravityNotFound
    /// Windows 主機還不支援(包裝腳本只有 POSIX 版)。
    case windowsUnsupported
}

/// Antigravity 方案用量的主機端(#448,ADR-0002 的寫入例外),比照 `ClaudePlanUsageHost`。
///
/// agy 只把 `quota` 交給 statusline 指令,所以經使用者同意後,把 `~/.gemini/antigravity-cli/settings.json`
/// 的 `statusLine.command` 換成 `~/.purrdr/antigravity-usage/statusline.sh`:它把輸入存成 `usage.json`
/// (有 `quota` 時)與每個 session 一份的 `sessions/<id>.json`,再把同一份輸入交給使用者原本的 statusline(存在 `original-command`)。
/// 沒有原本的 statusline 時裝成 `stack_with_default: true`:agy 內建狀態列照常,包裝腳本不輸出任何字;
/// 有原本的自訂 statusline 時保留它的 `stack_with_default`,畫面與安裝前相同。關閉時經 `ReversibleHostWrite` 還原。
public struct AntigravityPlanUsageHost: Sendable, ClaudeSessionStatusReading {
    public static let settingsPath: HostPath = ".gemini/antigravity-cli/settings.json"
    public static let feature = HostWriteFeature(id: "antigravity-usage", userFiles: [settingsPath])
    public static let usagePath = feature.ownFile("usage.json")
    /// 寫進 `statusLine.command` 的指令(agy 以 shell 執行,`~` 會展開)。
    public static let wrapperCommand = "~/.purrdr/antigravity-usage/statusline.sh"

    static func isWrapper(_ command: String?) -> Bool { command == wrapperCommand }

    let write: ReversibleHostWrite
    let files: HostFiles
    private let lastRead = LastRead()

    public init(channel: any HostChannel, files: HostFiles? = nil) {
        write = ReversibleHostWrite(channel: channel, feature: Self.feature)
        self.files = .shared(files, channel: channel)
    }

    /// 主機上有沒有裝 Antigravity(#465):唯讀,看 `~/.gemini/antigravity-cli` 在不在(只讀,不寫主機);Windows 沒有 Antigravity 用量,一律 `false`。
    public func isInstalledOnHost() async throws -> Bool {
        let read = try await files.read([Self.settingsPath])
        if read.operatingSystem == .windows { return false }
        if case .missingDirectory = read[Self.settingsPath] ?? .missing { return false }
        return true
    }

    /// 同意前的檢查:設定可以安全修改嗎、會以哪個使用者修改。
    public func inspect() async throws -> ClaudeUsageInspection {
        let inspection = try await write.inspect()
        if inspection.read.operatingSystem == .windows { throw AntigravityUsageError.windowsUnsupported }
        _ = try Self.currentSettings(in: inspection)
        return ClaudeUsageInspection(user: inspection.read.user, isInstalled: inspection.isInstalled)
    }

    /// 安裝包裝腳本。只在讀取後 `settings.json` 沒被改過時寫入(否則丟 `HostFilesError.changedSinceRead`)。
    public func install() async throws {
        try await write.install { inspection in
            if inspection.read.operatingSystem == .windows { throw AntigravityUsageError.windowsUnsupported }
            let current = try Self.currentSettings(in: inspection)
            var ownFiles: [String: HostWritePlan.OwnFile] = ["statusline.sh": .init(Data(Self.wrapperScript.utf8), executable: true)]
            // 包裝腳本永遠不會被存成「原本的」:否則執行時會一直呼叫自己。被使用者停用(enabled: false)的也不接。
            let originalLine = Self.statusLine(in: inspection.original(of: Self.settingsPath))
            let originalCommand = (originalLine?["command"] as? String).flatMap { command in
                !Self.isWrapper(command) && originalLine?["enabled"] as? Bool != false ? command : nil
            }
            if let originalCommand { ownFiles["original-command"] = .init(Data(originalCommand.utf8)) }
            let settings = try Self.settings(current) { statusLine in
                var statusLine = statusLine ?? [:]
                statusLine["type"] = "command"
                statusLine["command"] = Self.wrapperCommand
                statusLine["enabled"] = true
                // 沒有原本的自訂 statusline:疊在內建狀態列下面(包裝腳本不輸出);有就維持它原本的設定,畫面不變。
                if originalCommand == nil { statusLine["stack_with_default"] = true }
                return statusLine
            }
            return HostWritePlan(userFiles: [Self.settingsPath: settings], ownFiles: ownFiles)
        }
    }

    /// 還原原本的設定,移除 `~/.purrdr/antigravity-usage/`。
    public func restore() async throws {
        try await write.restore { _, current, original in
            guard let object = Self.jsonObject(current) else { throw AntigravityUsageError.settingsNotJSON }
            // 使用者已經自己換掉 statusline:不動它。
            guard Self.isWrapper(Self.statusLine(in: current)?["command"] as? String) else { return current }
            let originalLine = original.flatMap(Self.jsonObject)?["statusLine"] as? [String: Any]
            return try Self.settings(object) { _ in originalLine }
        }
    }

    /// 讀包裝腳本最後存下的用量;還沒有(沒安裝、agy 還沒回報)時是 `nil`。帶上次的版本條件式讀取,沒變時用上次的結果。
    public func readPlanUsage() async throws -> PlanUsage? {
        let previous = await lastRead.value
        let known: [HostPath: HostFileVersion] = previous.map { [Self.usagePath: $0.version] } ?? [:]
        let read = try await files.read([Self.usagePath], knownVersions: known)
        if let previous, read.unchanged.contains(Self.usagePath) { return previous.usage }
        let state = read[Self.usagePath]
        let usage = state?.contents.flatMap(PlanUsage.init(antigravityUsageFile:))
        if case .file(_, let version)? = state { await lastRead.update(Read(version: version, usage: usage)) } else { await lastRead.update(nil) }
        return usage
    }

    /// 各 session 的 statusline 狀態(`sessions/<id>.json`)。沒有檔案、讀不懂或過期的 session 不出現在結果;
    /// session id 不合規則(英數與 `. _ -`)就不讀。
    public func sessionStatuses(sessionIDs: [String]) async throws -> [String: ClaudeSessionStatus] {
        try await sessionStatuses(sessionIDs: sessionIDs, now: Date())
    }

    func sessionStatuses(sessionIDs: [String], now: Date) async throws -> [String: ClaudeSessionStatus] {
        let ids = sessionIDs.filter(ClaudeSessionStatus.isValidSessionID)
        guard !ids.isEmpty else { return [:] }
        let paths = Dictionary(uniqueKeysWithValues: Set(ids).map { ($0, Self.sessionPath($0)) })
        let read = try await files.read(Array(paths.values))
        var result: [String: ClaudeSessionStatus] = [:]
        for (id, path) in paths {
            guard case .file(let data, _)? = read[path], let status = ClaudeSessionStatus(sessionFile: data),
                  status.sessionID == id, status.isFresh(at: now) else { continue }
            result[id] = status
        }
        return result
    }

    static func sessionPath(_ id: String) -> HostPath { feature.ownFile("sessions/\(id).json") }

    // MARK: - 設定檔

    /// 目前的設定:不存在是空物件;所在資料夾不存在 → 沒裝 Antigravity;不是 JSON 物件 → 拒絕。
    static func currentSettings(in inspection: HostWriteInspection) throws -> [String: Any] {
        switch inspection.read[settingsPath] ?? .missing {
        case .missing:
            return [:]
        case .missingDirectory:
            throw AntigravityUsageError.antigravityNotFound
        case .file(let data, _):
            guard let object = jsonObject(data) else { throw AntigravityUsageError.settingsNotJSON }
            return object
        case .notRegularFile, .unreadable, .tooLarge:
            throw HostWriteError.unusableFile(settingsPath)
        }
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        guard StrictJSON.isValid(data) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func statusLine(in settings: Data?) -> [String: Any]? {
        settings.flatMap(jsonObject)?["statusLine"] as? [String: Any]
    }

    static func statusLine(in object: [String: Any]) -> [String: Any]? { object["statusLine"] as? [String: Any] }

    /// 改寫 `statusLine` 後輸出;回傳 `nil` 表示移除 `statusLine`。其他內容保留(鍵依字母排序)。
    static func settings(_ object: [String: Any], statusLine: ([String: Any]?) -> [String: Any]?) throws -> Data {
        var object = object
        object["statusLine"] = statusLine(object["statusLine"] as? [String: Any])
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    /// 包裝腳本(POSIX):每個 session 存一份 `sessions/<session_id>.json`,輸入有 `quota` 才存 `usage.json`,再把輸入交給原本的 statusline。
    /// 存檔失敗一律略過,不影響 statusline 的輸出;超過 7 天沒更新的 session 檔清掉。
    static let wrapperScript = #"""
    #!/bin/sh
    # Purrdr 的 Antigravity 方案用量包裝:由 Purrdr app 安裝,在 app 關閉「Antigravity 方案用量」就會還原。
    # 把 agy 交給 statusline 的輸入存起來,再原樣交給原本的 statusline:
    # - sessions/<session_id>.json:每次都寫(每個 session 一份)
    # - usage.json:輸入含 quota 時才寫(整台主機一份)
    dir="$HOME/.purrdr/antigravity-usage"
    input=$(cat)
    now=$(date +%s)

    # 以暫存檔寫好再換上(讀的一方不會讀到寫一半的檔)。$1 資料夾,$2 檔名,$3 內容。
    save() {
      tmp=$(mktemp "$1/.tmp.XXXXXX" 2>/dev/null) || return 0
      if printf '%s\n' "$3" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$1/$2" 2>/dev/null || rm -f "$tmp"
      else
        rm -f "$tmp"
      fi
    }

    session=$(printf '%s' "$input" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]{1,128})".*/\1/p' | head -n 1)
    case $session in
      '' | . | ..) ;;
      *)
        if mkdir -p "$dir/sessions" 2>/dev/null; then
          save "$dir/sessions" "$session.json" "{\"captured_at\":$now,\"session_id\":\"$session\",\"status_line_input\":$input}"
          find "$dir/sessions" -type f -name '*.json' -mmin +10080 -exec rm -f {} + 2>/dev/null
        fi
        ;;
    esac
    case $input in
      *'"quota"'*)
        if mkdir -p "$dir" 2>/dev/null; then
          save "$dir" usage.json "{\"captured_at\":$now,\"status_line_input\":$input}"
        fi
        ;;
    esac

    # 原本的 statusline 的輸出與結束碼直接交給 agy;沒有原本的就不輸出。
    if [ -s "$dir/original-command" ]; then
      printf '%s\n' "$input" | sh -c "$(cat "$dir/original-command")"
    fi

    """#
}

extension PlanUsage {
    /// 解析包裝腳本存的 `usage.json`:`{"captured_at":<epoch 秒>,"status_line_input":<agy 的輸入>}`。
    /// `quota` 的 bucket:`gemini-5h`、`gemini-weekly`(Gemini 模型)與 `3p-5h`、`3p-weekly`(第三方模型),
    /// `remaining_fraction`(0～1)換成已用百分比、`reset_time` 是 ISO 8601。`disabled` 或缺剩餘比例的略過;
    /// 沒記載的 bucket(例如 `gemini-argon-wtu-weekly`)忽略,不因為多出新的 bucket 壞掉。
    public init?(antigravityUsageFile data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let capturedAt = (object["captured_at"] as? NSNumber)?.doubleValue,
              let input = object["status_line_input"] as? [String: Any],
              let quota = input["quota"] as? [String: Any]
        else { return nil }
        let buckets: [(String, Group, Period.Kind)] = [
            ("gemini-5h", .gemini, .fiveHour), ("gemini-weekly", .gemini, .week),
            ("3p-5h", .thirdParty, .fiveHour), ("3p-weekly", .thirdParty, .week),
        ]
        let periods: [Period] = buckets.compactMap { key, group, kind in
            guard let bucket = quota[key] as? [String: Any], bucket["disabled"] as? Bool != true,
                  let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (bucket["reset_time"] as? String).flatMap { Self.resetDate($0) }
            return Period(kind: kind, group: group, usedPercentage: Period.clamped((1 - remaining) * 100), resetsAt: resets)
        }
        let model = input["model"] as? [String: Any]
        let modelName = model?["id"] as? String ?? model?["display_name"] as? String
        self.init(
            periods: periods, capturedAt: Date(timeIntervalSince1970: capturedAt), activeGroup: modelName.flatMap(Group.init(modelName:)))
    }

    private static func resetDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

private struct Read {
    let version: HostFileVersion
    let usage: PlanUsage?
}

private actor LastRead {
    private(set) var value: Read?
    func update(_ read: Read?) { value = read }
}
