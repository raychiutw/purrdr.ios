import Foundation

/// 主機回報的絕對路徑：POSIX 的 `/…`,或 Windows 的磁碟機路徑 `C:\…`(也接受 `C:/…`)。
/// 驗證規則不分主機(行為規格 §11.1「檔案路徑一律以 `/` 開頭驗證 → 依主機 OS 驗證」);UNC(`\\server\share`)不接受。
public enum HostPathSyntax {
    static func isAbsolute(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        return isWindowsDrivePath(path)
    }

    /// `C:\…` 或 `C:/…`。
    static func isWindowsDrivePath(_ path: String) -> Bool {
        let characters = Array(path.prefix(3))
        return characters.count == 3 && characters[0].isASCII && characters[0].isLetter && characters[1] == ":"
            && (characters[2] == "\\" || characters[2] == "/")
    }

    /// 以 `/` 與 `\`(Windows 路徑)分段。
    static func components(_ path: String) -> [Substring] {
        isWindowsDrivePath(path) ? path.split(whereSeparator: { $0 == "/" || $0 == "\\" }) : path.split(separator: "/")
    }

    /// 最後一段(資料夾名稱等顯示用)。
    public static func lastComponent(_ path: String) -> Substring? { components(path).last }

    /// 絕對路徑、沒有 `..` 段、沒有 NUL／CR／LF。
    static func isSafeAbsolute(_ path: String) -> Bool {
        isAbsolute(path) && !components(path).contains("..") && !path.contains { $0 == "\0" || $0 == "\r" || $0 == "\n" }
    }

    /// 絕對路徑，最後一段剛好是 `name`。
    static func isAbsolute(_ path: String, endingWith name: String) -> Bool {
        isAbsolute(path) && !path.contains("\n") && lastComponent(path).map(String.init) == name
            && (path.hasSuffix("/" + name) || path.hasSuffix("\\" + name))
    }
}
