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
    var parentDirectories: [HostPath] {
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
    var journalPath: HostPath { ownFile("journal.json") }
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

/// 可還原的主機寫入(ADR-0002)。會寫入主機的功能(Claude 用量、主題、Codex 啟動器、推播外掛…)都經過這裡：
///
/// - **安裝**:一次往返讀使用者檔案與安裝紀錄，交給功能算出新內容，再一次往返以 compare-and-swap 寫入
///   (讀取之後檔案被改過就整批不寫)。安裝紀錄記下每個使用者檔案安裝前的內容;重複安裝沿用第一次的紀錄。
/// - **還原**:使用者檔案仍是安裝寫入的樣子 → 換回安裝前的內容(原本不存在就刪除),與安裝前完全相同;
///   安裝後使用者又改過 → 交給功能的 `merge` 只撤掉自己的修改。最後移除 `~/.purrdr/<id>/`。
///
/// 是否徵得同意由呼叫端(畫面 model)負責，見 `HostWriteConsentStore`。
public struct ReversibleHostWrite: Sendable {
    public let feature: HostWriteFeature
    let files: HostFiles

    public init(channel: any HostChannel, feature: HostWriteFeature) {
        self.feature = feature
        files = HostFiles(channel: channel)
    }

    /// 讀使用者檔案、安裝紀錄與 `extra`(例如功能自己的資料檔)。
    public func inspect(also extra: [HostPath] = []) async throws -> HostWriteInspection {
        let directories = feature.createsParentDirectories ? feature.parentDirectories : []
        let read = try await files.read(feature.userFiles + [feature.journalPath] + directories + extra)
        let journal: HostWriteJournal?
        switch read[feature.journalPath] {
        case .file(let data, _)?:
            guard let decoded = try? JSONDecoder().decode(HostWriteJournal.self, from: data) else {
                throw HostWriteError.unreadableJournal(feature.journalPath)
            }
            journal = decoded
        default:
            journal = nil
        }
        return HostWriteInspection(read: read, journal: journal)
    }

    /// 安裝。`plan` 拿到目前的主機狀態，回傳要寫的內容;它丟出的錯誤原樣傳出(例如設定檔不是合法 JSON)。
    public func install(_ plan: (HostWriteInspection) throws -> HostWritePlan) async throws {
        let inspection = try await inspect()
        let plan = try plan(inspection)
        var journal = HostWriteJournal(entries: inspection.journal?.entries.filter { plan.userFiles[HostPath($0.path)] == nil } ?? [])
        var userChanges: [HostFileChange] = []
        for path in feature.userFiles {
            guard let contents = plan.userFiles[path] else { continue }
            journal.entries.append(.init(path: path.relative, original: inspection.original(of: path), installed: contents))
            userChanges.append(.write(path, contents, executable: plan.executableUserFiles.contains(path),
                                      expecting: try Self.expectation(for: inspection.read[path], at: path)))
        }
        let ownChanges = plan.ownFiles.keys.sorted().map { name in
            HostFileChange.write(feature.ownFile(name), plan.ownFiles[name]!.contents, executable: plan.ownFiles[name]!.executable, expecting: .anything)
        }
        // 不存在的上層資料夾(由淺到深)由安裝建立，記在紀錄裡;重複安裝時保留第一次建的。
        var created = inspection.journal?.createdDirectories ?? []
        var directoryChanges: [HostFileChange] = []
        if feature.createsParentDirectories {
            for directory in feature.parentDirectories {
                switch inspection.read[directory] {
                case .missing?, .missingDirectory?:
                    directoryChanges.append(.makeDirectory(directory))
                    if !created.contains(directory.relative) { created.append(directory.relative) }
                default:
                    continue
                }
            }
        }
        journal.createdDirectories = created.isEmpty ? nil : created
        // 先寫自己的檔案，使用者檔案最後寫：中途失敗時使用者檔案還沒動。
        try await files.apply([.write(feature.journalPath, try Self.encode(journal), expecting: .anything)] + ownChanges + directoryChanges + userChanges)
    }

    /// 還原。沒有安裝紀錄時什麼都不做。
    ///
    /// - Parameter merge: 使用者在安裝後又改過檔案時呼叫，拿到目前內容與安裝前內容，回傳撤掉功能修改後的內容。
    public func restore(merge: (HostPath, _ current: Data, _ original: Data?) throws -> Data) async throws {
        let inspection = try await inspect()
        guard let journal = inspection.journal else { return }
        var changes: [HostFileChange] = []
        for entry in journal.entries {
            let path = HostPath(entry.path)
            switch inspection.read[path] ?? .missing {
            case .file(let current, let version):
                let target = current == entry.installed ? entry.original : try merge(path, current, entry.original)
                if let target {
                    if target != current { changes.append(.write(path, target, expecting: .version(version))) }
                } else {
                    changes.append(.delete(path, expecting: .version(version)))
                }
            case .missing, .missingDirectory:
                // 安裝後使用者自己刪掉了：尊重使用者，不再建立。
                continue
            case .notRegularFile, .unreadable, .tooLarge:
                throw HostWriteError.unusableFile(path)
            }
        }
        // 自己建的資料夾由深到淺，空了才移除(使用者後來放了東西就保留)。
        let directories = (journal.createdDirectories ?? []).reversed().map { HostFileChange.removeEmptyDirectory(HostPath($0)) }
        try await files.apply(changes + directories + [.removeDirectory(feature.directory)])
    }

    static func expectation(for state: HostFileState?, at path: HostPath) throws -> HostFileExpectation {
        switch state ?? .missing {
        case .file(_, let version): .version(version)
        case .missing, .missingDirectory: .missing
        case .notRegularFile, .unreadable, .tooLarge: throw HostWriteError.unusableFile(path)
        }
    }

    static func encode(_ journal: HostWriteJournal) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(journal)
    }
}

public enum HostWriteError: Error, Equatable {
    /// 使用者檔案不是一般檔案、讀不到或太大，不能安全地修改。
    case unusableFile(HostPath)
    /// 安裝紀錄壞了，無法得知原本的內容。
    case unreadableJournal(HostPath)
}
