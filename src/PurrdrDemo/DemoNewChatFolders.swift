import Foundation
import PurrdrCore

/// Demo 主機的資料夾(新增對話的資料夾瀏覽，行為規格 F3.3)。只有資料夾，內容自己寫。
enum DemoNewChatFolders {
    static let home = "/Users/demo"

    private static let tree: [String: [String]] = [
        "/": ["Users"],
        "/Users": ["demo"],
        home: ["ledger", "notes", "weather-app"],
        home + "/ledger": ["reports"],
        home + "/ledger/reports": [],
        home + "/notes": [],
        home + "/weather-app": [],
    ]

    /// `NewChatFolders` 的指令才回應;其他指令回 `nil`。不存在的資料夾 exit 66(與主機腳本相同)。
    static func respond(to command: String) -> (stdout: Data, exitCode: Int32)? {
        guard let requested = NewChatFolders.requestedPath(in: command) else { return nil }
        let path = absolute(requested)
        guard let folders = tree[path] else { return (Data(), 66) }
        return (NewChatFolders.output(path: path, folders: folders), 0)
    }

    private static func absolute(_ requested: String) -> String {
        var path = requested
        if path.isEmpty || path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + "/" + path.dropFirst(2)
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
