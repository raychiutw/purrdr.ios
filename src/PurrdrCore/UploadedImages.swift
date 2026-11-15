import Foundation

/// Prompt 中的上傳圖片(行為規格 F6.5、F6.6、F7)。
///
/// 送出：打的字 + 空一行 + 每張一行絕對路徑(只有圖片時就是路徑)。
/// 讀回：Claude 把路徑行換成 `[Image #N]`,另記一個 `[Image: source: <路徑>]`;Codex 保留原行。
/// 兩種都變成圖片，`[Image #N]` 移除，剩下的必須剛好是使用者打的字(回音才配得上)。
public enum UploadedImages {
    /// 主機上的上傳資料夾(相對家目錄;`ImageUploadCommand` 寫到這裡)。
    public static let folder = ".purrdr/uploads"
    static let extensions = ["jpg", "jpeg", "png", "heic", "webp"]

    public static func prompt(text: String, paths: [String]) -> String {
        guard !paths.isEmpty else { return text }
        let joined = paths.joined(separator: "\n")
        return text.isEmpty ? joined : text + "\n\n" + joined
    }

    /// 把使用者文字拆成「打的字」與圖片路徑(依出現順序、不重複)。
    public static func extract(from text: String) -> (text: String, paths: [String]) {
        var kept: [Substring] = []
        var paths: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let path = sourcePath(trimmed) ?? (isUploadPath(trimmed) ? trimmed : nil) {
                if !paths.contains(path) { paths.append(path) }
                continue
            }
            let stripped = String(line).replacingMatches(#"\[Image #\d+\]"#, with: "")
            if stripped != String(line), stripped.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            kept.append(Substring(stripped))
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }

    /// `[Image: source: <路徑>]`(Claude 的註記)。
    private static func sourcePath(_ line: String) -> String? {
        let prefix = "[Image: source: "
        guard line.hasPrefix(prefix), line.hasSuffix("]") else { return nil }
        let path = String(line.dropFirst(prefix.count).dropLast())
        return path.isEmpty ? nil : path
    }

    /// 一整行是上傳資料夾底下的圖片絕對路徑。
    static func isUploadPath(_ line: String) -> Bool {
        guard line.hasPrefix("/"), !line.contains(" ") else { return false }
        let components = line.split(separator: "/")
        guard components.count >= 4, let name = components.last,
              components[components.count - 2] == "uploads", components[components.count - 3] == ".purrdr",
              let ext = name.split(separator: ".").last, name.contains(".") else { return false }
        return extensions.contains(ext.lowercased())
    }
}
