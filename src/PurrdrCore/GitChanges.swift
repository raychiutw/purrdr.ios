import Foundation

/// 變更頁(#310):Agent 工作目錄的唯讀 git 變更清單與 diff。
///
/// adapter:HTTPS(`HTTPSHostConnection`,主機服務的 `git.status`／`git.diff`,raychiutw/purrdr.host#33)、
/// SSH(`SSHGitChanges`,經主機通道跑唯讀 git 指令)、測試用 Fake;做不到的連線方式或主機回 `GitChangesError.unsupported`。
public protocol GitChangesReading: Sendable {
    /// `cwd` 所在 repo 工作目錄相對 HEAD 的變更清單。
    func gitStatus(cwd: String) async throws -> GitWorkingTreeStatus
    /// 變更檔案的 diff;`path`(相對 repo 根目錄)有值時只回那個檔案。
    func gitDiff(cwd: String, path: String?) async throws -> GitDiffSet
}

public typealias GitChangeKind = HostServiceProtocol.GitChangeKind
public typealias GitDiffOmission = HostServiceProtocol.GitDiffOmitted

/// 一個變更的檔案;`path` 相對 repo 根目錄，以 `/` 分隔。
public struct GitChange: Sendable, Hashable {
    public var path: String
    public var kind: GitChangeKind

    public init(path: String, kind: GitChangeKind) {
        self.path = path
        self.kind = kind
    }
}

public struct GitWorkingTreeStatus: Sendable, Equatable {
    /// 目前分支;detached HEAD 時是 `nil`。
    public var branch: String?
    /// 依路徑排序。
    public var files: [GitChange]

    public init(branch: String?, files: [GitChange]) {
        self.branch = branch
        self.files = files
    }
}

/// 一個檔案的 diff:hunk 文字(`@@` 開頭，不含 `---`／`+++` 檔頭),或不顯示的原因。
public struct GitFileDiff: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case hunks(String)
        case omitted(GitDiffOmission)
    }

    public var path: String
    public var kind: GitChangeKind
    public var content: Content

    public init(path: String, kind: GitChangeKind, content: Content) {
        self.path = path
        self.kind = kind
        self.content = content
    }
}

public struct GitDiffSet: Sendable, Equatable {
    public var files: [GitFileDiff]
    /// 總量超過上限：之後的檔案只列路徑(標 `.tooLarge`),要單獨再讀。
    public var truncated: Bool

    public init(files: [GitFileDiff], truncated: Bool) {
        self.files = files
        self.truncated = truncated
    }
}

public enum GitChangesError: Error, Equatable, Sendable {
    /// 這個連線方式或主機還讀不了(例如 Windows 主機、Demo 主機沒有 git)。
    case unsupported
    /// 工作目錄不在 git repo 裡。
    case notGitRepository
    /// 主機服務：`cwd` 不是 herdr 目前回報的 Agent 工作目錄(Agent 已換資料夾或結束)。
    case cwdNotAllowed
    /// 主機沒有 `git` 指令(SSH)。
    case gitNotInstalled
    /// 主機回應格式不對或指令失敗。
    case failed(String)
}

/// 沒有 git 讀取的連線方式。
public struct UnsupportedGitChanges: GitChangesReading {
    public init() {}

    public func gitStatus(cwd: String) async throws -> GitWorkingTreeStatus { throw GitChangesError.unsupported }
    public func gitDiff(cwd: String, path: String?) async throws -> GitDiffSet { throw GitChangesError.unsupported }
}

// MARK: - diff 的行

/// diff 的一行。`id` 是在這個檔案 diff 裡的序號(評論以它定位)。
public struct GitDiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case hunkHeader
        case context
        case added
        case removed
        /// `\ No newline at end of file` 之類的附註。
        case note
    }

    public var id: Int
    public var kind: Kind
    /// 去掉 `+`／`-`／空白前綴的內容(標頭與附註是整行)。
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?

    public init(id: Int, kind: Kind, text: String, oldLine: Int?, newLine: Int?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }

    /// 評論引用時的行號：新檔的行號，刪除的行用舊檔的。
    public var number: Int? { newLine ?? oldLine }

    /// diff 裡原本的樣子(帶 `+`／`-`／空白前綴)。
    public var diffText: String {
        switch kind {
        case .added: "+" + text
        case .removed: "-" + text
        case .context: " " + text
        case .hunkHeader, .note: text
        }
    }

    /// 可以寫評論的行(有內容的行，不是標頭或附註)。
    public var isCommentable: Bool { number != nil }
}

public enum GitDiffLines {
    /// 把 unified diff 的 hunk 拆成行，依 `@@ -舊起始,數 +新起始,數 @@` 算出每行的行號。
    public static func parse(_ hunks: String) -> [GitDiffLine] {
        var rows = hunks.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if rows.last == "" { rows.removeLast() }
        var lines: [GitDiffLine] = []
        var old = 0, new = 0
        for row in rows {
            let id = lines.count
            if row.hasPrefix("@@") {
                (old, new) = starts(ofHunkHeader: row)
                lines.append(GitDiffLine(id: id, kind: .hunkHeader, text: row, oldLine: nil, newLine: nil))
                continue
            }
            let body = String(row.dropFirst())
            switch row.first {
            case "+":
                lines.append(GitDiffLine(id: id, kind: .added, text: body, oldLine: nil, newLine: new))
                new += 1
            case "-":
                lines.append(GitDiffLine(id: id, kind: .removed, text: body, oldLine: old, newLine: nil))
                old += 1
            case "\\":
                lines.append(GitDiffLine(id: id, kind: .note, text: row, oldLine: nil, newLine: nil))
            default:
                // 前後文以空白開頭;空行(有些工具去掉了行尾空白)也當前後文。
                lines.append(GitDiffLine(id: id, kind: .context, text: body, oldLine: old, newLine: new))
                old += 1
                new += 1
            }
        }
        return lines
    }

    /// `@@ -舊起始[,數] +新起始[,數] @@` 的兩個起始行號;數是 0 時起始行號是「前一行」,下一行從它加 1 算起(只有新增或刪除時不會用到)。
    private static func starts(ofHunkHeader header: String) -> (old: Int, new: Int) {
        let fields = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let field = fields.first(where: { $0.first == prefix }) else { return 0 }
            let range = field.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            let first = Int(range.first ?? "") ?? 0
            let count = range.count > 1 ? Int(range[1]) ?? 1 : 1
            return count == 0 ? first + 1 : first
        }
        return (start("-"), start("+"))
    }
}

/// 一個檔案的 +/− 行數。
public struct GitDiffStats: Sendable, Equatable {
    public var added: Int
    public var removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }

    public init(_ lines: [GitDiffLine]) {
        self.init(added: lines.count { $0.kind == .added }, removed: lines.count { $0.kind == .removed })
    }
}

// MARK: - 行內評論

/// diff 某一行上的評論。
public struct GitReviewComment: Sendable, Equatable, Identifiable {
    public var path: String
    public var line: GitDiffLine
    public var body: String

    public init(path: String, line: GitDiffLine, body: String) {
        self.path = path
        self.line = line
        self.body = body
    }

    public var id: String { "\(path)#\(line.id)" }
}

public enum GitReviewMessage {
    /// 評論組成一則給 Agent 的訊息：依 `fileOrder`(變更清單)與行的順序，每則是「路徑:行號」、引用那一行、評論，以空行分隔。
    /// 不含要翻譯的文字(Agent 看得懂路徑與引用)。
    public static func compose(_ comments: [GitReviewComment], fileOrder: [String]) -> String {
        let rank = Dictionary(fileOrder.enumerated().map { ($1, $0) }) { first, _ in first }
        return comments
            .filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ((rank[$0.path] ?? Int.max), $0.path, $0.line.id) < ((rank[$1.path] ?? Int.max), $1.path, $1.line.id) }
            .map { comment in
                let location = comment.line.number.map { "\(comment.path):\($0)" } ?? comment.path
                return [location, "> " + comment.line.diffText, comment.body.trimmingCharacters(in: .whitespacesAndNewlines)].joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }
}
