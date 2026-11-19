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
    /// 點擊載入的上限(schema 的 `x-maximum-file-size`,主機端也以它拒讀)。
    public static let maximumSize = HostServiceProtocol.maximumFileSize
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
    /// 目前的對話紀錄(它的附檔資料夾 `<資料夾>/<檔名去掉副檔名>/tool-results` 可放行提到的路徑)。
    public var transcriptPaths: [String]

    public init(workingDirectories: [String], mentionedPaths: Set<String>, transcriptPaths: [String] = []) {
        self.workingDirectories = workingDirectories
        self.mentionedPaths = mentionedPaths
        self.transcriptPaths = transcriptPaths
    }
}


extension HostFileAccessScope {
    /// 對話紀錄裡 Agent 自己寫出的路徑：檔案卡片(寫檔、讀圖、MCP 圖片、圖片生成)、工具呼叫的檔案路徑，
    /// 與 Agent 訊息文字中的主機路徑(#229)。使用者訊息與工具結果的內容不算(主機服務同一套規則)。
    public static func mentionedPaths(in items: [ConversationItem]) -> Set<String> {
        var mentioned: Set<String> = []
        for item in items {
            switch item {
            case .agentFile(let card): mentioned.insert(card.file.path)
            case .agentText(let text): mentioned.formUnion(HostPathMention.paths(in: text.markdown))
            case .toolRun(let run):
                for step in run.steps {
                    if case .call(let call) = step.kind, let path = call.path { mentioned.insert(path) }
                }
            default: break
            }
        }
        return mentioned
    }
}

/// 主機取檔的存取規則(app 端提前擋;主機端再檢查，是權威)。與主機服務、SSH 取檔腳本共用案例 `protocol/host-file-access.json`。
///
/// - Agent 工作目錄之下;工作目錄是根目錄、家目錄或它的上層時不算(等於放行整個家目錄)。
/// - 或 Agent 在對話紀錄寫出的路徑，且在系統暫存目錄、家目錄的 `.purrdr/uploads`、Windows 的 `AppData\Local\Temp`,
///   或目前對話紀錄的附檔資料夾(`<資料夾>/<檔名去掉副檔名>/tool-results`)。
/// - 排除清單一律拒絕。app 不知道主機的家目錄，依路徑樣式推測(`/Users/<名稱>`、`/home/<名稱>`、`C:\Users\<名稱>`…)。
public enum HostFileAccessPolicy {
    public enum Decision: Sendable, Equatable {
        case allowed(HostFileTarget)
        case denied
    }

    /// 排除清單：路徑任何位置連續出現這些段落就不讀(不分大小寫;`*` 結尾比對開頭)。定義在主機服務協定 schema 的
    /// `x-excluded-file-locations`,SSH 取檔腳本(`HostFileFetchScript`)與主機服務(#227)用同一份。
    package static let excludedLocations = HostServiceProtocol.excludedFileLocations

    public static func decision(for path: String, in scope: HostFileAccessScope) -> Decision {
        guard let pathKeys = HostPathKeys(path), !isExcluded(pathKeys.segments) else { return .denied }
        for directory in scope.workingDirectories {
            guard let rootKeys = HostPathKeys(directory), !rootKeys.isTooBroadForWorkingDirectory else { continue }
            if pathKeys.isUnder(rootKeys) { return .allowed(HostFileTarget(path: path, root: directory)) }
        }
        guard scope.mentionedPaths.contains(path), mentionableLocations(for: pathKeys, in: scope).contains(where: pathKeys.isUnder) else {
            return .denied
        }
        return .allowed(HostFileTarget(path: path, root: nil))
    }

    /// 工作目錄以外，Agent 提到時可放行的位置。
    private static func mentionableLocations(for path: HostPathKeys, in scope: HostFileAccessScope) -> [HostPathKeys] {
        var locations = HostServiceProtocol.temporaryFileLocations.compactMap(HostPathKeys.init)
        if let home = path.inferredHome {
            locations.append(home.appending(path.isWindows ? ["appdata", "local", "temp"] : ["AppData", "Local", "Temp"]))
            locations.append(home.appending([".purrdr", "uploads"]))
        }
        for transcript in scope.transcriptPaths {
            guard let keys = HostPathKeys(transcript), let name = keys.segments.last else { continue }
            let stem = name.split(separator: ".", omittingEmptySubsequences: false).dropLast().joined(separator: ".")
            locations.append(HostPathKeys(segments: Array(keys.segments.dropLast()) + [stem.isEmpty ? name : stem, "tool-results"], isWindows: keys.isWindows))
        }
        return locations
    }

    private static func isExcluded(_ segments: [String]) -> Bool {
        let folded = segments.map { $0.lowercased() }
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

/// 比對用的路徑段落:Windows 磁碟機路徑轉小寫(含磁碟機代號),POSIX 保留大小寫。
private struct HostPathKeys: Equatable {
    var segments: [String]
    var isWindows: Bool

    init(segments: [String], isWindows: Bool) {
        self.segments = segments
        self.isWindows = isWindows
    }

    /// 絕對路徑;相對路徑、`.`／`..`、控制字元、Windows 的 ADS(`:`)與 UNC 回 `nil`。
    init?(_ path: String) {
        guard HostPathSyntax.isAbsolute(path), !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return nil
        }
        let isWindows = HostPathSyntax.isWindowsDrivePath(path)
        guard !isWindows || !path.dropFirst(2).contains(":") else { return nil }
        let segments = HostPathSyntax.components(path).map(String.init)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        self.init(segments: isWindows ? segments.map { $0.lowercased() } : segments, isWindows: isWindows)
    }

    func isUnder(_ root: HostPathKeys) -> Bool {
        isWindows == root.isWindows && segments.count > root.segments.count && Array(segments.prefix(root.segments.count)) == root.segments
    }

    func appending(_ more: [String]) -> HostPathKeys {
        HostPathKeys(segments: segments + more, isWindows: isWindows)
    }

    /// 段落數：磁碟機代號不算。
    private var depth: Int { isWindows ? segments.count - 1 : segments.count }

    /// 路徑樣式推測的家目錄:`/Users/<名稱>`、`/home/<名稱>`、`/root`、`/var/root`、`C:\Users\<名稱>`。
    var inferredHome: HostPathKeys? {
        let named = isWindows ? Array(segments.dropFirst()) : segments
        let homeLength: Int? = switch named.first {
        case "Users" where !isWindows, "home" where !isWindows, "users" where isWindows: named.count >= 2 ? 2 : nil
        case "root" where !isWindows: 1
        case "var" where !isWindows: named.count >= 2 && named[1] == "root" ? 2 : nil
        default: nil
        }
        return homeLength.map { HostPathKeys(segments: Array(segments.prefix($0 + (isWindows ? 1 : 0))), isWindows: isWindows) }
    }

    /// 根目錄、家目錄或家目錄的上層(`/Users`、`/home`、`/var`、`C:\Users`)。
    var isTooBroadForWorkingDirectory: Bool {
        if depth == 0 { return true }
        let named = isWindows ? Array(segments.dropFirst()) : segments
        if isWindows { return named.first == "users" && depth <= 2 }
        switch named.first {
        case "Users", "home": return depth <= 2
        case "root": return depth == 1
        case "var": return depth == 1 || (depth == 2 && named[1] == "root")
        default: return false
        }
    }
}
