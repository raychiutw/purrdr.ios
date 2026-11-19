import Foundation

/// 主機取檔(GLOSSARY「主機取檔」,#225):從主機讀 Agent 碰過的檔案。只有兩個操作——查狀態、依版本分塊讀取。
///
/// adapter:SSH(`SSHHostFileFetcher`,長駐通道跑 `HostFileFetchScript`)、HTTPS(`HTTPSHostConnection`,主機服務的
/// `file.stat`／`file.read`,#227)、Demo、測試用 Fake;還沒支援的連線方式或主機回 `HostFileFetchError.unsupported`。
/// 存取規則在呼叫前由 `HostFileAccessPolicy` 檢查(app 端),主機端再檢查一次(權威)。
public protocol HostFileFetching: Sendable {
    /// 查狀態：存在、大小、版本。
    func status(of target: HostFileTarget) async throws -> HostFileStatus
    /// 依版本讀 `offset` 起最多 `length` bytes;主機上的檔案已不是這個版本時丟 `HostFileFetchError.changed`。
    func read(_ target: HostFileTarget, version: HostFileVersion, offset: Int, length: Int) async throws -> Data
}

/// 要讀的檔案：主機絕對路徑，與允許它的工作目錄(對話紀錄出現過而允許的是 `nil`)。
public struct HostFileTarget: Sendable, Hashable {
    public var path: String
    /// 主機端以它解析 symlink 後比對「在工作目錄之下」;`nil` 表示只檢查排除清單。
    public var root: String?

    public init(path: String, root: String?) {
        self.path = path
        self.root = root
    }
}

/// 主機上一個檔案的狀態。
public enum HostFileStatus: Sendable, Equatable {
    case file(version: HostFileVersion, size: Int)
    case missing
    /// 資料夾、FIFO、裝置等不是一般檔案。
    case notRegularFile
    case unreadable
    /// 主機端的存取規則不允許(解析 symlink 後跳出工作目錄，或在排除清單)。
    case denied
    /// 超過主機取檔的上限(`HostFileFetchLimits.maximumSize`)。
    case tooLarge(size: Int)
}

public enum HostFileFetchError: Error, Equatable {
    /// 這個連線方式或主機還不能取檔。
    case unsupported
    /// 讀取時主機上的檔案已不是要求的版本。
    case changed
    /// 狀態不是一般檔案(缺檔、被拒…)。
    case unavailable(HostFileStatus)
    /// 主機回應格式不對或通道失敗。
    case failed(String)
}

/// 主機取檔的大小與分塊。
public enum HostFileFetchLimits {
    /// 圖片自動載入縮圖的上限;超過顯示大小與「點擊載入」。
    public static let automaticLoad = 8 * 1024 * 1024
    /// 點擊載入的上限(主機端也以它拒讀)。
    public static let maximumSize = 25 * 1024 * 1024
    /// 每次讀取的 bytes(base64 後約 256 KiB,不長時間占住通道)。
    public static let chunkSize = 192 * 1024
}

/// 沒有取檔能力的連線方式。
public struct UnsupportedHostFileFetcher: HostFileFetching {
    public init() {}

    public func status(of target: HostFileTarget) async throws -> HostFileStatus {
        throw HostFileFetchError.unsupported
    }

    public func read(_ target: HostFileTarget, version: HostFileVersion, offset: Int, length: Int) async throws -> Data {
        throw HostFileFetchError.unsupported
    }
}

/// 存取規則的範圍：Agent 的工作目錄，與這段對話紀錄中出現過的檔案路徑。
public struct HostFileAccessScope: Sendable, Equatable {
    public var workingDirectories: [String]
    public var mentionedPaths: Set<String>

    public init(workingDirectories: [String], mentionedPaths: Set<String>) {
        self.workingDirectories = workingDirectories
        self.mentionedPaths = mentionedPaths
    }
}

extension HostFileAccessScope {
    /// 對話紀錄裡出現過的路徑：檔案卡片的路徑，與 Agent 訊息文字中的主機路徑(#229)。
    public static func mentionedPaths(in items: [ConversationItem]) -> Set<String> {
        var mentioned: Set<String> = []
        for item in items {
            switch item {
            case .agentFile(let card): mentioned.insert(card.file.path)
            case .agentText(let text): mentioned.formUnion(HostPathMention.paths(in: text.markdown))
            default: break
            }
        }
        return mentioned
    }
}

/// 主機取檔的存取規則(app 端提前擋;主機端腳本解析 symlink 後再檢查，是權威)。
public enum HostFileAccessPolicy {
    public enum Decision: Sendable, Equatable {
        case allowed(HostFileTarget)
        case denied
    }

    /// 排除清單：路徑任何位置連續出現這些段落就不讀(不分大小寫;`*` 結尾比對開頭)。定義在主機服務協定 schema 的
    /// `x-excluded-file-locations`,SSH 取檔腳本(`HostFileFetchScript`)與主機服務(#227)用同一份。
    package static let excludedLocations = HostServiceProtocol.excludedFileLocations

    public static func decision(for path: String, in scope: HostFileAccessScope) -> Decision {
        guard let components = components(of: path), !isExcluded(components) else { return .denied }
        let folded = components.map { $0.lowercased() }
        for directory in scope.workingDirectories {
            guard let root = Self.components(of: directory) else { continue }
            let isWindows = HostPathSyntax.isWindowsDrivePath(directory)
            let rootKeys = isWindows ? root.map { $0.lowercased() } : root
            let pathKeys = isWindows ? folded : components
            if pathKeys.count > rootKeys.count, Array(pathKeys.prefix(rootKeys.count)) == rootKeys {
                return .allowed(HostFileTarget(path: path, root: directory))
            }
        }
        return scope.mentionedPaths.contains(path) ? .allowed(HostFileTarget(path: path, root: nil)) : .denied
    }

    /// 絕對路徑的段落;相對路徑、`.`／`..`、空段落以外的空白路徑、控制字元回 `nil`。
    private static func components(of path: String) -> [String]? {
        guard HostPathSyntax.isAbsolute(path), !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return nil
        }
        let components = HostPathSyntax.components(path).map(String.init)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return components
    }

    private static func isExcluded(_ components: [String]) -> Bool {
        let folded = components.map { $0.lowercased() }
        return excludedLocations.contains { location in
            let pattern = location.lowercased().split(separator: "/").map(String.init)
            guard pattern.count <= folded.count else { return false }
            return (0...(folded.count - pattern.count)).contains { start in
                zip(pattern, folded[start...]).allSatisfy { expected, actual in
                    expected.hasSuffix("*") ? actual.hasPrefix(expected.dropLast()) : actual == expected
                }
            }
        }
    }
}
