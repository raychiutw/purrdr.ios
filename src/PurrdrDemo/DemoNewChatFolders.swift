import Foundation
import PurrdrCore
import PurrdrSSH

/// Demo 主機的資料夾(新增對話的資料夾瀏覽，行為規格 F3.3)。與檔案瀏覽同一棵樹(`DemoFolders.initialTree`),只列資料夾。
enum DemoNewChatFolders {
    static let home = DemoFolders.home

    /// `NewChatFolders` 的指令才回應;其他指令回 `nil`。不存在的資料夾 exit 66(與主機腳本相同)。
    static func respond(to command: String) -> (stdout: Data, exitCode: Int32)? {
        guard let requested = SSHNewChatFolders.requestedPath(in: command) else { return nil }
        let path = absolute(requested)
        guard let items = DemoFolders.initialTree[path] else { return (Data(), 66) }
        return (SSHNewChatFolders.output(path: path, folders: items.filter(\.isFolder).map(\.name)), 0)
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
