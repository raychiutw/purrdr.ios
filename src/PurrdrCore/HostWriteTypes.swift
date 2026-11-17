// 可還原主機寫入的領域型別(功能、安裝紀錄、計畫、錯誤);經主機通道執行的 `ReversibleHostWrite` 在 PurrdrSSH。
import Foundation

/// 一個會寫入主機的功能(ADR-0002):它會修改哪些使用者檔案，自己的檔案放在 `~/.purrdr/<id>/`。
public struct HostWriteFeature: Sendable, Equatable {
    /// 功能代號，也是 `~/.purrdr/` 底下的資料夾名稱(小寫英數與 `-`)。
    public let id: String
    /// 會修改的使用者檔案(不在 `.purrdr/` 底下的)。
    public let userFiles: [HostPath]
    /// 使用者檔案所在的資料夾不存在時由安裝建立(例如 `~/.local/bin`);建了哪些記在安裝紀錄，還原時資料夾空了就移除。
    public let createsParentDirectories: Bool

    public init(id: String, userFiles: [HostPath], createsParentDirectories: Bool = false) {
        self.id = id
        self.userFiles = userFiles
        self.createsParentDirectories = createsParentDirectories
    }

    /// 使用者檔案的上層資料夾(由淺到深，不含家目錄本身)。
    package var parentDirectories: [HostPath] {
        var result: [HostPath] = []
        for path in userFiles {
            let segments = path.relative.split(separator: "/").dropLast()
            for depth in segments.indices {
                let directory = HostPath(segments[...depth].joined(separator: "/"))
                if !result.contains(directory) { result.append(directory) }
            }
        }
        return result
    }

    /// `~/.purrdr/<id>`
    public var directory: HostPath { HostPath(".purrdr/\(id)") }
    /// 功能自己的檔案路徑。
    public func ownFile(_ name: String) -> HostPath { HostPath(".purrdr/\(id)/\(name)") }
    package var journalPath: HostPath { ownFile("journal.json") }
}

/// 安裝紀錄：每個改過的使用者檔案，安裝前與安裝後的內容。放在 `~/.purrdr/<id>/journal.json`。
public struct HostWriteJournal: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        /// 安裝前的內容;`nil` 表示原本不存在。
        public var original: Data?
        /// 安裝寫入的內容。
        public var installed: Data

        public init(path: String, original: Data?, installed: Data) {
            self.path = path
            self.original = original
            self.installed = installed
        }
    }

    public var version = 1
    public var entries: [Entry]
    /// 安裝時建立的資料夾(由淺到深;舊的紀錄沒有這個欄位)。
    public var createdDirectories: [String]?

    public init(entries: [Entry], createdDirectories: [String]? = nil) {
        self.entries = entries
        self.createdDirectories = createdDirectories
    }

    public func entry(for path: HostPath) -> Entry? { entries.first { $0.path == path.relative } }
}

/// 安裝或還原前讀到的主機狀態。
public struct HostWriteInspection: Sendable, Equatable {
    /// 使用者檔案與額外要求讀的檔案。`read.user` 是執行的主機使用者。
    public var read: HostFileRead
    public var journal: HostWriteJournal?

    package init(read: HostFileRead, journal: HostWriteJournal?) {
        self.read = read
        self.journal = journal
    }

    /// 有安裝紀錄就算已安裝。
    public var isInstalled: Bool { journal != nil }

    /// 這個檔案「安裝前」的內容：有安裝紀錄時用紀錄裡的(重複安裝不會把安裝後的內容當成原本的),否則用目前的。
    public func original(of path: HostPath) -> Data? {
        if let entry = journal?.entry(for: path) { return entry.original }
        return read[path]?.contents
    }
}

/// 一次安裝要寫的內容。
public struct HostWritePlan: Sendable {
    public struct OwnFile: Sendable {
        public var contents: Data
        public var executable: Bool

        public init(_ contents: Data, executable: Bool = false) {
            self.contents = contents
            self.executable = executable
        }
    }

    /// 使用者檔案的新內容。
    public var userFiles: [HostPath: Data]
    /// 功能自己的檔案(`~/.purrdr/<id>/<名稱>`)。
    public var ownFiles: [String: OwnFile]
    /// 要設成可執行的使用者檔案(例如 Codex 啟動器)。
    public var executableUserFiles: Set<HostPath>

    public init(userFiles: [HostPath: Data], ownFiles: [String: OwnFile], executableUserFiles: Set<HostPath> = []) {
        self.userFiles = userFiles
        self.ownFiles = ownFiles
        self.executableUserFiles = executableUserFiles
    }
}

public enum HostWriteError: Error, Equatable {
    /// 使用者檔案不是一般檔案、讀不到或太大，不能安全地修改。
    case unusableFile(HostPath)
    /// 安裝紀錄壞了，無法得知原本的內容。
    case unreadableJournal(HostPath)
}
