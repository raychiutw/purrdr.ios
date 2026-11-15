import Foundation
import PurrdrCore

/// Demo 主機的家目錄：記憶體裡的假檔案，回應主機檔案的讀寫指令(`HostFileRequest`)。
///
/// 一開始只有 `~/.claude/settings.json`(範例的 status line 設定)。Claude 用量的包裝腳本裝上之後，
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

    private var files: [String: Data] = [".claude/settings.json": Data(sampleSettings.utf8)]
    /// 一定存在的資料夾(家目錄與 `~/.claude`)。
    private let baseDirectories: Set<String> = ["", ".claude"]

    mutating func handle(_ request: HostFileRequest, now: Date) -> (stdout: Data, exitCode: Int32) {
        switch request {
        case .read(let paths):
            return (HostFileRequest.readOutput(user: Self.user, files: paths.map { state(of: $0, now: now) }), 0)
        case .apply(let changes):
            for change in changes {
                if let failure = check(change) { return failure }
            }
            changes.forEach { apply($0) }
            return (Data(), 0)
        }
    }

    private func state(of path: HostPath, now: Date) -> HostFileState {
        if path == ClaudeUsageHost.usagePath, files[ClaudeUsageHost.feature.ownFile("statusline.sh").relative] != nil {
            let data = Self.sampleUsage(now: now)
            return .file(data, version: Self.version(of: data))
        }
        if let data = files[path.relative] { return .file(data, version: Self.version(of: data)) }
        return directoryExists(Self.parent(of: path.relative)) ? .missing : .missingDirectory
    }

    private func check(_ change: HostFileChange) -> (stdout: Data, exitCode: Int32)? {
        let expectation: HostFileExpectation
        switch change {
        case .write(_, _, _, let expected), .delete(_, let expected): expectation = expected
        case .removeDirectory: return nil
        }
        let current = files[change.path.relative]
        let matches = switch expectation {
        case .anything: true
        case .missing: current == nil
        case .version(let version): current.map(Self.version(of:)) == version
        }
        guard matches else { return (HostFileRequest.changedSinceReadOutput(change.path), HostFileRequest.ExitCode.changedSinceRead) }
        if case .write = change, !change.path.relative.hasPrefix(".purrdr/"), !directoryExists(Self.parent(of: change.path.relative)) {
            return (HostFileRequest.missingDirectoryOutput(change.path), HostFileRequest.ExitCode.missingDirectory)
        }
        return nil
    }

    private mutating func apply(_ change: HostFileChange) {
        switch change {
        case .write(let path, let data, _, _): files[path.relative] = data
        case .delete(let path, _): files[path.relative] = nil
        case .removeDirectory(let path): files = files.filter { !$0.key.hasPrefix(path.relative + "/") }
        }
    }

    private func directoryExists(_ directory: String) -> Bool {
        baseDirectories.contains(directory) || files.keys.contains { $0.hasPrefix(directory + "/") }
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
}
