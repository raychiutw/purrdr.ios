import Foundation
import PurrdrCore
import PurrdrSSH

/// Demo 主機的家目錄：記憶體裡的假檔案，回應主機檔案的讀寫指令(`HostFileRequest`)。
///
/// 一開始有 `~/.claude/settings.json`(範例的 status line 設定)、herdr 的 `config.toml`(主題)與「You should know」的 store。Claude 方案用量的包裝腳本裝上之後，
/// 讀 `usage.json` 會拿到範例用量——就像 Claude Code 已經執行過包裝腳本(行為規格 F21:用量是假資料)。
struct DemoFiles {
    static let user = "demo"
    static let sampleSettings = """
        {
          "statusLine": {
            "type": "command",
            "command": "~/.claude/statusline.sh"
          }
        }

        """

    /// herdr 的設定：Demo 用 tokyo-night(主機主題，#23)。
    static let sampleHerdrConfig = """
        # herdr config (Purrdr demo)
        [theme]
        name = "tokyo-night"

        """
    static let youShouldKnowStore = ".claude/plugins/store/cc-plugin-you-should-know_builtin-d3m0d3m0d3m0.json"
    /// 「You should know」的 store(#23):給 ledger(w1:p1)的一則註記(內容自己寫的)。
    static let sampleYouShouldKnow = """
        {"sessions":[{"id":"d3m0d3m0-0000-4000-8000-000000000001","view":{"kind":"offer",\
        "line":"Decimal keeps cents exact where Double rounds them","explanation":\
        "Double stores binary fractions, so 0.1 + 0.2 isn't 0.3. Swift's Decimal works in base 10, which is why money totals stay exact.",\
        "shownAt":1763280000000}}],"known":[],"typedPastInARow":0,"looksToSkip":0}
        """

    /// Antigravity 的設定(#448):沒有自己的 statusline,方案用量的包裝裝上去後讀到範例用量。
    static let sampleAntigravitySettings = """
        {
          "model": "gemini-4-neon"
        }

        """

    private var files: [String: Data] = [
        ".claude/settings.json": Data(sampleSettings.utf8),
        AntigravityPlanUsageHost.settingsPath.relative: Data(sampleAntigravitySettings.utf8),
        ".config/herdr/config.toml": Data(sampleHerdrConfig.utf8),
        youShouldKnowStore: Data(sampleYouShouldKnow.utf8),
    ]
    /// 一定存在的資料夾(家目錄與 `~/.claude`)。
    private let baseDirectories: Set<String> = ["", ".claude", ".gemini", ".gemini/antigravity-cli"]
    /// 主機寫入建立的資料夾(例如 Codex 啟動器的 `~/.local/bin`)。
    private var madeDirectories: Set<String> = []

    mutating func handle(_ request: HostFileRequest, now: Date) -> (stdout: Data, exitCode: Int32) {
        switch request {
        case .read(let paths):
            return (HostFileRequest.readOutput(user: Self.user, files: paths.map { state(of: $0, now: now) }), 0)
        case .readIfChanged(let paths, let known):
            return (HostFileRequest.readIfChangedOutput(user: Self.user, paths: paths, files: paths.map { state(of: $0, now: now) }, known: known), 0)
        case .apply(let changes):
            var made: Set<String> = []
            for change in changes {
                if let failure = check(change, made: &made) { return failure }
            }
            changes.forEach { apply($0) }
            return (Data(), 0)
        case .newest(let directory, let prefix, let suffix):
            // Demo 的檔案沒有修改時間：符合的取路徑排序最後一個。
            let match = files.keys.filter {
                guard $0.hasPrefix(directory.relative + "/") else { return false }
                let name = String($0.dropFirst(directory.relative.count + 1))
                return !name.contains("/") && name.hasPrefix(prefix) && name.hasSuffix(suffix)
            }.max()
            return (HostFileRequest.newestOutput(match.map { HostPath($0) }), 0)
        }
    }

    private func state(of path: HostPath, now: Date) -> HostFileState {
        if path == ClaudePlanUsageHost.usagePath, files[ClaudePlanUsageHost.feature.ownFile("statusline.sh").relative] != nil {
            let data = Self.sampleUsage(now: now)
            return .file(data, version: Self.version(of: data))
        }
        if path == AntigravityPlanUsageHost.usagePath, files[AntigravityPlanUsageHost.feature.ownFile("statusline.sh").relative] != nil {
            let data = Self.sampleAntigravityUsage(now: now)
            return .file(data, version: Self.version(of: data))
        }
        if let data = files[path.relative] { return .file(data, version: Self.version(of: data)) }
        if directoryExists(path.relative) { return .notRegularFile }
        return directoryExists(Self.parent(of: path.relative)) ? .missing : .missingDirectory
    }

    private func check(_ change: HostFileChange, made: inout Set<String>) -> (stdout: Data, exitCode: Int32)? {
        let expectation: HostFileExpectation
        switch change {
        case .write(_, _, _, let expected), .delete(_, let expected): expectation = expected
        case .removeDirectory, .removeEmptyDirectory: return nil
        case .makeDirectory(let path):
            if files[path.relative] != nil || directoryExists(path.relative) {
                return (HostFileRequest.changedSinceReadOutput(path), HostFileRequest.ExitCode.changedSinceRead)
            }
            made.insert(path.relative)
            return nil
        }
        let current = files[change.path.relative]
        let matches = switch expectation {
        case .anything: true
        case .missing: current == nil
        case .version(let version): current.map(Self.version(of:)) == version
        }
        guard matches else { return (HostFileRequest.changedSinceReadOutput(change.path), HostFileRequest.ExitCode.changedSinceRead) }
        let parent = Self.parent(of: change.path.relative)
        if case .write = change, !change.path.relative.hasPrefix(".purrdr/"), !directoryExists(parent), !made.contains(parent) {
            return (HostFileRequest.missingDirectoryOutput(change.path), HostFileRequest.ExitCode.missingDirectory)
        }
        return nil
    }

    private mutating func apply(_ change: HostFileChange) {
        switch change {
        case .write(let path, let data, _, _): files[path.relative] = data
        case .delete(let path, _): files[path.relative] = nil
        case .removeDirectory(let path): files = files.filter { !$0.key.hasPrefix(path.relative + "/") }
        case .makeDirectory(let path): madeDirectories.insert(path.relative)
        case .removeEmptyDirectory(let path):
            let prefix = path.relative + "/"
            if !files.keys.contains(where: { $0.hasPrefix(prefix) }), !madeDirectories.contains(where: { $0.hasPrefix(prefix) }) {
                madeDirectories.remove(path.relative)
            }
        }
    }

    private func directoryExists(_ directory: String) -> Bool {
        baseDirectories.contains(directory) || madeDirectories.contains(directory) || files.keys.contains { $0.hasPrefix(directory + "/") }
    }

    private static func parent(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// 內容的版本(Demo 自己的格式;client 只拿來比對)。
    private static func version(of data: Data) -> HostFileVersion {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return HostFileVersion(checksum: "\(hash):\(data.count)")
    }

    /// 一分鐘前擷取的範例用量：5 小時用了 38%、2 小時 13 分後重置;每週用了 61%、3 天後重置。
    static func sampleUsage(now: Date) -> Data {
        let now = Int(now.timeIntervalSince1970)
        return Data(#"""
            {"captured_at":\#(now - 60),"status_line_input":{"model":{"display_name":"Opus"},"rate_limits":{\#
            "five_hour":{"used_percentage":38,"resets_at":\#(now + 2 * 3600 + 13 * 60)},\#
            "seven_day":{"used_percentage":61,"resets_at":\#(now + 3 * 86400)}}}}
            """#.utf8)
    }

    /// 一分鐘前擷取的 Antigravity 範例用量(#448):目前模型 Gemini 4 Neon;Gemini 群組 5 小時用了 9%、每週用了 3%,
    /// 第三方群組 5 小時用了 40%、每週用了 62%。
    static func sampleAntigravityUsage(now: Date) -> Data {
        let now = Int(now.timeIntervalSince1970)
        func time(_ offset: Int) -> String { Date(timeIntervalSince1970: TimeInterval(now + offset)).formatted(.iso8601) }
        return Data(#"""
            {"captured_at":\#(now - 60),"status_line_input":{"model":{"id":"Gemini 4 Neon (Medium)"},"quota":{\#
            "gemini-5h":{"remaining_fraction":0.91,"reset_time":"\#(time(2 * 3600 + 13 * 60))"},\#
            "gemini-weekly":{"remaining_fraction":0.97,"reset_time":"\#(time(4 * 86400))"},\#
            "3p-5h":{"remaining_fraction":0.6,"reset_time":"\#(time(3 * 3600))"},\#
            "3p-weekly":{"remaining_fraction":0.38,"reset_time":"\#(time(2 * 86400))"}}}}
            """#.utf8)
    }
}
