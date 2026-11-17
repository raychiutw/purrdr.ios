import Foundation
import PurrdrCore

/// Demo 主機的資料夾(檔案瀏覽，行為規格 F13):家目錄 `/Users/demo` 與三個 workspace 的資料夾。
/// 新增對話的資料夾瀏覽(`DemoNewChatFolders`)也用同一棵樹(`initialTree` 裡的資料夾)。
///
/// 回應 `HostFolderCommand` 的精確指令，輸出與主機腳本相同的格式(`pwd` + `ls -lnA`)。
/// 上傳的檔案只記名稱與大小(內容不保存),重開 app 就消失。
struct DemoFolders {
    struct Item {
        var name: String
        var isFolder: Bool
        var size: Int
    }

    static let home = "/Users/demo"

    /// 一開始的內容(上傳前)。
    static let initialTree: [String: [Item]] = [
        "/Users/demo": [
            Item(name: "ledger", isFolder: true, size: 160),
            Item(name: "notes", isFolder: true, size: 128),
            Item(name: "weather-app", isFolder: true, size: 192),
            Item(name: ".zshrc", isFolder: false, size: 214),
            Item(name: "README.md", isFolder: false, size: 1_380),
        ],
        "/Users/demo/ledger": [
            Item(name: "reports", isFolder: true, size: 64),
            Item(name: "export.csv", isFolder: false, size: 48_211),
            Item(name: "ledger.py", isFolder: false, size: 6_532),
        ],
        "/Users/demo/ledger/reports": [],
        "/Users/demo/notes": [
            Item(name: "inbox.md", isFolder: false, size: 912),
        ],
        "/Users/demo/weather-app": [
            Item(name: "forecast.swift", isFolder: false, size: 3_074),
            Item(name: "Package.swift", isFolder: false, size: 611),
        ],
        "/Users": [
            Item(name: "demo", isFolder: true, size: 256),
        ],
        "/": [
            Item(name: "Users", isFolder: true, size: 160),
        ],
    ]

    private var folders = Self.initialTree

    /// 清單指令的結果(stdout、stderr、exit code)。
    func list(_ path: String?) -> (stdout: Data, stderr: Data, exitCode: Int32) {
        let target = path ?? Self.home
        guard let items = folders[target] else {
            return (Data(), Data("sh: cd: \(target): No such file or directory\n".utf8), 66)
        }
        var lines = [target, "total \(items.count * 8)"]
        for item in items {
            let mode = item.isFolder ? "drwxr-xr-x" : "-rw-r--r--"
            lines.append("\(mode)  1 501  20  \(item.size) Nov 16 09:41 \(item.name)")
        }
        return (Data((lines.joined(separator: "\n") + "\n").utf8), Data(), 0)
    }

    /// 上傳:資料夾不存在 exit 66、同名 exit 73、收到的 bytes 與傳輸大小不符 exit 75;成功時以原始大小記下檔案並回傳路徑
    /// (gzip 傳輸不解壓)。
    mutating func upload(folder: String, name: String, size: Int, transferSize: Int, received: Int) -> (stdout: Data, exitCode: Int32) {
        guard folders[folder] != nil else { return (Data(), 66) }
        guard received == transferSize else { return (Data(), 75) }
        guard !(folders[folder] ?? []).contains(where: { $0.name == name }) else { return (Data(), 73) }
        folders[folder, default: []].append(Item(name: name, isFolder: false, size: size))
        return (Data("\(folder == "/" ? "" : folder)/\(name)\n".utf8), 0)
    }
}

/// Demo 的上傳：收 stdin 到 EOF,再交給 `DemoHost` 決定結果。
actor DemoUploadSession: ExecSession {
    nonisolated let output: AsyncThrowingStream<ExecOutput, any Error>
    private let continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation
    private let finish: @Sendable (Int) async -> (stdout: Data, exitCode: Int32)
    private var received = 0
    private var done = false

    init(finish: @escaping @Sendable (Int) async -> (stdout: Data, exitCode: Int32)) {
        (output, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
        self.finish = finish
    }

    func write(_ data: Data) async throws {
        guard !done else { return }
        received += data.count
    }

    func closeStdin() async {
        guard !done else { return }
        done = true
        let result = await finish(received)
        if !result.stdout.isEmpty { continuation.yield(.stdout(result.stdout)) }
        continuation.yield(.exit(code: result.exitCode))
        continuation.finish()
    }

    func close() async {
        guard !done else { return }
        done = true
        continuation.finish(throwing: CancellationError())
    }
}
