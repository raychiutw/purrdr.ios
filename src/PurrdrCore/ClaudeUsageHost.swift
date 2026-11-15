import Foundation

/// Claude 用量的主機端(行為規格 F18,ADR-0002 的寫入例外)。
///
/// Claude Code 只把 `rate_limits` 交給 status line 指令，所以經使用者同意後，把 `~/.claude/settings.json`
/// 的 `statusLine.command` 換成 `~/.purrdr/claude-usage/statusline.sh`:它把輸入存成 `usage.json`,
/// 再把同一份輸入交給使用者原本的 status line(原本的指令存在 `original-command`)。
/// 關閉時經 `ReversibleHostWrite` 還原，主機與安裝前完全相同。
public struct ClaudeUsageHost: Sendable {
    public static let settingsPath: HostPath = ".claude/settings.json"
    public static let feature = HostWriteFeature(id: "claude-usage", userFiles: [settingsPath])
    public static let usagePath = feature.ownFile("usage.json")
    /// 寫進 `statusLine.command` 的指令(Claude Code 以 shell 執行，`~` 會展開)。
    public static let wrapperCommand = "~/.purrdr/claude-usage/statusline.sh"

    let write: ReversibleHostWrite
    let files: HostFiles

    public init(channel: any HostChannel) {
        write = ReversibleHostWrite(channel: channel, feature: Self.feature)
        files = HostFiles(channel: channel)
    }

    /// 同意前的檢查：設定可以安全修改嗎、會以哪個使用者修改。
    public func inspect() async throws -> ClaudeUsageInspection {
        let inspection = try await write.inspect()
        _ = try Self.currentSettings(in: inspection)
        return ClaudeUsageInspection(user: inspection.read.user, isInstalled: inspection.isInstalled)
    }

    /// 安裝包裝腳本。只在讀取後 `settings.json` 沒被改過時寫入(否則丟 `HostFilesError.changedSinceRead`)。
    public func install() async throws {
        try await write.install { inspection in
            let current = try Self.currentSettings(in: inspection)
            var ownFiles: [String: HostWritePlan.OwnFile] = ["statusline.sh": .init(Data(Self.wrapperScript.utf8), executable: true)]
            // 包裝腳本永遠不會被存成「原本的」:否則執行時會一直呼叫自己。
            if let original = Self.statusLineCommand(in: inspection.original(of: Self.settingsPath)), original != Self.wrapperCommand {
                ownFiles["original-command"] = .init(Data(original.utf8))
            }
            let settings = try Self.settings(current) { statusLine in
                var statusLine = statusLine ?? [:]
                statusLine["type"] = "command"
                statusLine["command"] = Self.wrapperCommand
                return statusLine
            }
            return HostWritePlan(userFiles: [Self.settingsPath: settings], ownFiles: ownFiles)
        }
    }

    /// 還原原本的設定，移除 `~/.purrdr/claude-usage/`。
    public func restore() async throws {
        try await write.restore { _, current, original in
            guard let object = Self.jsonObject(current) else { throw ClaudeUsageError.settingsNotJSON }
            // 使用者已經自己換掉 status line:不動它。
            guard Self.statusLineCommand(in: current) == Self.wrapperCommand else { return current }
            let originalStatusLine = original.flatMap(Self.jsonObject)?["statusLine"] as? [String: Any]
            return try Self.settings(object) { _ in originalStatusLine }
        }
    }

    /// 讀包裝腳本最後存下的用量;還沒有(沒安裝、Claude Code 還沒回報)時是 `nil`。
    public func readUsage() async throws -> ClaudeUsage? {
        let read = try await files.read([Self.usagePath])
        return read[Self.usagePath]?.contents.flatMap(ClaudeUsage.init(usageFile:))
    }

    // MARK: - 設定檔

    /// 目前的設定：不存在是空物件;所在資料夾不存在 → 沒裝 Claude Code;不是 JSON 物件 → 拒絕。
    static func currentSettings(in inspection: HostWriteInspection) throws -> [String: Any] {
        switch inspection.read[settingsPath] ?? .missing {
        case .missing:
            return [:]
        case .missingDirectory:
            throw ClaudeUsageError.claudeNotFound
        case .file(let data, _):
            guard let object = jsonObject(data) else { throw ClaudeUsageError.settingsNotJSON }
            return object
        case .notRegularFile, .unreadable, .tooLarge:
            throw HostWriteError.unusableFile(settingsPath)
        }
    }

    /// 只接受 Claude Code 也讀得了的嚴格 JSON 物件。
    static func jsonObject(_ data: Data) -> [String: Any]? {
        guard StrictJSON.isValid(data) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func statusLineCommand(in settings: Data?) -> String? {
        (settings.flatMap(jsonObject)?["statusLine"] as? [String: Any])?["command"] as? String
    }

    /// 改寫 `statusLine` 後輸出;回傳 `nil` 表示移除 `statusLine`。其他內容保留(鍵依字母排序)。
    /// 還原時若使用者沒再改過，會換回安裝前的原始 bytes,所以排序只在安裝期間看得到。
    static func settings(_ object: [String: Any], statusLine: ([String: Any]?) -> [String: Any]?) throws -> Data {
        var object = object
        object["statusLine"] = statusLine(object["statusLine"] as? [String: Any])
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    /// 包裝腳本。輸入有 `rate_limits` 才存(session 剛開始時沒有，不蓋掉上次的用量)。
    static let wrapperScript = """
        #!/bin/sh
        # Purrdr 的 Claude 用量包裝：由 Purrdr app 安裝，在 app 關閉「Claude 用量」就會還原。
        # 把 Claude Code 交給 status line 的輸入存成 usage.json,再原樣交給原本的 status line。
        dir="$HOME/.purrdr/claude-usage"
        input=$(cat)
        case $input in
          *'"rate_limits"'*)
            if tmp=$(mktemp "$dir/.usage.XXXXXX"); then
              if printf '{"captured_at":%s,"status_line_input":%s}\\n' "$(date +%s)" "$input" > "$tmp"; then
                mv -f "$tmp" "$dir/usage.json" || rm -f "$tmp"
              else
                rm -f "$tmp"
              fi
            fi
            ;;
        esac
        if [ -s "$dir/original-command" ]; then
          printf '%s\\n' "$input" | sh -c "$(cat "$dir/original-command")"
        fi

        """
}

extension ClaudeUsage {
    /// 解析包裝腳本存的 `usage.json`:`{"captured_at":<epoch 秒>,"status_line_input":<Claude Code 的輸入>}`。
    /// `rate_limits.<視窗>.resets_at` 是 Unix epoch 秒(Claude Code 文件)。
    public init?(usageFile data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let capturedAt = (object["captured_at"] as? NSNumber)?.doubleValue,
              let limits = (object["status_line_input"] as? [String: Any])?["rate_limits"] as? [String: Any]
        else { return nil }
        func window(_ key: String) -> Window? {
            guard let window = limits[key] as? [String: Any], let used = (window["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return Window(usedPercentage: used, resetsAt: (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        self.init(fiveHour: window("five_hour"), week: window("seven_day"), capturedAt: Date(timeIntervalSince1970: capturedAt))
    }
}
