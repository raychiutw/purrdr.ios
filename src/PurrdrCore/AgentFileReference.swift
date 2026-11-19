import Foundation

/// 對話紀錄裡 Agent 碰到的一個主機檔案(GLOSSARY「Agent 檔案參照」)。畫面依此顯示檔案卡片。
public struct AgentFileReference: Sendable, Equatable, Codable {
    /// Agent 對這個檔案做了什麼。
    public enum Origin: String, Sendable, Codable {
        /// `Write` 新建。
        case created
        /// `Write` 覆寫既有檔案。
        case overwritten
        /// `Edit`／`MultiEdit` 修改。
        case edited
    }

    public var origin: Origin
    /// 主機上的絕對路徑(Windows 主機是 `C:\…`)。
    public var path: String
    /// 對話紀錄當時記下的內容或修改摘要;沒有記錄時為 `nil`。
    public var snapshot: AgentFileSnapshot?
    /// 檔案大小(bytes);不知道時為 `nil`。
    public var byteCount: Int?

    public init(origin: Origin, path: String, snapshot: AgentFileSnapshot? = nil, byteCount: Int? = nil) {
        self.origin = origin
        self.path = path
        self.snapshot = snapshot
        self.byteCount = byteCount
    }

    /// 快照(寫入內容、修改摘要)最多保留的字數;超過時截斷並標示。
    public static let snapshotLimit = 20_000

    /// 檔名(路徑最後一段)。
    public var name: String {
        HostPathSyntax.lastComponent(path).map(String.init) ?? path
    }
}

extension AgentFileReference {
    /// Claude 工具結果行頂層的 `toolUseResult` → 檔案參照(欄位依 #223 錄製樣本，沒有官方 schema)。
    /// `Write` 帶 `type: create／update` 與 `content`;`Edit` 沒有 `type`,帶 `structuredPatch`。其他結果回 `nil`。
    static func claudeToolResult(_ result: [String: Any]) -> AgentFileReference? {
        guard let path = result["filePath"] as? String, !path.isEmpty else { return nil }
        switch result["type"] as? String {
        case "create", "update":
            guard let content = result["content"] as? String else { return nil }
            return AgentFileReference(
                origin: result["type"] as? String == "create" ? .created : .overwritten, path: path,
                snapshot: .content(String(content.prefix(snapshotLimit)), isTruncated: content.count > snapshotLimit),
                byteCount: content.utf8.count
            )
        case nil:
            guard let patch = result["structuredPatch"] as? [[String: Any]] else { return nil }
            return AgentFileReference(origin: .edited, path: path, snapshot: .edit(AgentFileEdit(claudePatch: patch)))
        default:
            return nil
        }
    }
}

extension AgentFileEdit {
    init(claudePatch: [[String: Any]]) {
        let hunks = claudePatch.map { hunk in
            AgentFileHunk(
                oldStart: hunk["oldStart"] as? Int ?? 0, oldLines: hunk["oldLines"] as? Int ?? 0,
                newStart: hunk["newStart"] as? Int ?? 0, newLines: hunk["newLines"] as? Int ?? 0,
                lines: hunk["lines"] as? [String] ?? []
            )
        }
        let lines = hunks.flatMap(\.lines)
        // hunk 依序保留到總字數達上限;增刪行數照完整的 patch 算。
        var kept: [AgentFileHunk] = []
        var budget = AgentFileReference.snapshotLimit
        for var hunk in hunks {
            let fitting = hunk.lines.prefix { line in
                budget -= line.count + 1
                return budget >= 0
            }
            guard fitting.count == hunk.lines.count else {
                hunk.lines = Array(fitting)
                if !hunk.lines.isEmpty { kept.append(hunk) }
                break
            }
            kept.append(hunk)
        }
        self.init(hunks: kept, addedLines: lines.count { $0.hasPrefix("+") }, removedLines: lines.count { $0.hasPrefix("-") },
                  isTruncated: kept != hunks)
    }
}

/// 檔案類型(依副檔名)。畫面依此選圖示與類型名稱。
public enum AgentFileKind: String, Sendable, Codable {
    case text, markdown, code, image, pdf, data, other
}

extension AgentFileReference {
    /// 檔案類型。
    public var kind: AgentFileKind {
        switch fileExtension {
        case "txt", "log", "text": .text
        case "md", "markdown", "mdx": .markdown
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff", "svg": .image
        case "pdf": .pdf
        case "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "xml", "plist": .data
        case "swift", "kt", "java", "rs", "go", "py", "rb", "js", "jsx", "ts", "tsx", "c", "h", "cc", "cpp", "hpp", "m", "mm",
             "cs", "php", "sh", "bash", "zsh", "ps1", "sql", "html", "css", "scss", "lua", "dart", "scala": .code
        default: .other
        }
    }

    /// 小寫副檔名(沒有時是空字串)。
    public var fileExtension: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}

/// 對話紀錄當時記下的檔案狀態，離線也能顯示。
public enum AgentFileSnapshot: Sendable, Equatable, Codable {
    /// 寫入的完整內容(超過上限時截斷)。
    case content(String, isTruncated: Bool)
    /// 修改摘要。
    case edit(AgentFileEdit)
}

/// 一次修改的摘要:unified diff 的 hunk 與增刪行數。
public struct AgentFileEdit: Sendable, Equatable, Codable {
    public var hunks: [AgentFileHunk]
    public var addedLines: Int
    public var removedLines: Int
    /// hunk 超過上限被截斷(增刪行數仍是完整的)。
    public var isTruncated: Bool

    public init(hunks: [AgentFileHunk], addedLines: Int, removedLines: Int, isTruncated: Bool = false) {
        self.hunks = hunks
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.isTruncated = isTruncated
    }
}

/// unified diff 的一段;`lines` 以 ` `／`-`／`+` 開頭，或是 `\ No newline at end of file`。
public struct AgentFileHunk: Sendable, Equatable, Codable {
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    public var lines: [String]

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [String]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }
}
