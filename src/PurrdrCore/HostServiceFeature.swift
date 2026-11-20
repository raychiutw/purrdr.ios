import Foundation

/// 主機服務的版本(`welcome` 的 `host_service_version`),依數字比較。
///
/// `1.2.3` 讀成三段數字;缺的段補 0(`1.2` 與 `1.2.0` 相同),預發行標記(`-beta`)之後不比。
public struct HostServiceVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// 看不懂的版本字串回傳 `nil`。
    public init?(_ text: String) {
        let core = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap(\.self) + Array(repeating: 0, count: 3 - parts.count)
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        [lhs.major, lhs.minor, lhs.patch].lexicographicallyPrecedes([rhs.major, rhs.minor, rhs.patch])
    }
}

/// HTTPS 主機依主機服務版本啟用的功能(#283)。新功能在這裡加一個 case 並在 `minimumVersion` 登記門檻，
/// 再於 `HTTPSHostConnection` 送出前呼叫 `requireHostService(_:)`;版本不足丟 `HostServiceError.hostServiceUpdateRequired`。
public enum HostServiceFeature: String, Sendable, Hashable, CaseIterable {
    /// 主機取檔 `file.stat`／`file.read`(#227)。
    case fileFetch
    /// 上傳圖片與檔案 `file.upload.start`／`file.upload.chunk`(#288)。
    case fileUpload
    /// 列表預覽與 subagent／workflow／委派讀取(`transcript.previews`／`.subagent`／`.workflow`／`.delegation`,#289)。
    case transcriptPreviewsAndDelegations

    /// 有這個功能的第一個主機服務版本。
    public var minimumVersion: HostServiceVersion {
        switch self {
        case .fileFetch: HostServiceVersion(0, 4, 0)
        case .fileUpload: HostServiceVersion(0, 7, 0)
        case .transcriptPreviewsAndDelegations: HostServiceVersion(0, 7, 0)
        }
    }

    /// 回報 `installedVersion` 的主機服務有沒有這個功能;沒回報或看不懂的版本算沒有。
    public func isAvailable(onHostServiceVersion installedVersion: String?) -> Bool {
        guard let installed = installedVersion.flatMap(HostServiceVersion.init) else { return false }
        return installed >= minimumVersion
    }
}
