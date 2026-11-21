import Foundation
import PurrdrCore

/// 最新的主機服務版本從哪裡來(#362)。取不到時回 `nil`,呼叫端就不提示更新(不誤報)。
public protocol HostServiceReleaseSource: Sendable {
    func latestVersion() async -> String?
}

/// 固定的最新版本：測試與 UI 測試用(不連網路)。`nil` 是取不到。
public struct FixedHostServiceReleases: HostServiceReleaseSource {
    /// UI 測試的最新版本(只是測試用的數字，跟實際發行的版本無關)。
    public static let uiTestingLatestVersion = "1.0.0"
    /// UI 測試：最新版是 `uiTestingLatestVersion`。
    public static let uiTesting = FixedHostServiceReleases(uiTestingLatestVersion)

    public let latest: String?

    public init(_ latest: String?) {
        self.latest = latest
    }

    public func latestVersion() async -> String? { latest }
}

/// 從 raychiutw/purrdr.host 的最新 GitHub Release 取得(公開 repo,不需要權杖)。
///
/// 主機服務每次發版，app 不用改版號或重新包版就知道有新版。Release 的 tag 是 `host-service-v<版本>`。
/// 取得的版本快取 `cacheDuration`(未帶權杖的 GitHub API 每個 IP 每小時 60 次;以單調時鐘計時，不受改系統時間影響);
/// 失敗不快取，下次再試。同時查只送一個請求。
public actor GitHubHostServiceReleases: HostServiceReleaseSource {
    static let repository = "raychiutw/purrdr.host"
    static let tagPrefix = "host-service-v"

    private let session: URLSession
    private let apiBaseURL: URL
    private let cacheDuration: Duration
    private let clock = ContinuousClock()
    private var cached: (version: String, fetchedAt: ContinuousClock.Instant)?
    private var inFlight: Task<String?, Never>?

    public init(
        session: URLSession = .shared, apiBaseURL: URL = URL(string: "https://api.github.com")!, cacheDuration: Duration = .seconds(6 * 60 * 60)
    ) {
        self.session = session
        self.apiBaseURL = apiBaseURL
        self.cacheDuration = cacheDuration
    }

    public func latestVersion() async -> String? {
        if let cached, cached.fetchedAt.duration(to: clock.now) < cacheDuration { return cached.version }
        if let inFlight { return await inFlight.value }
        let (session, apiBaseURL) = (session, apiBaseURL)
        let task = Task { await Self.fetch(session: session, apiBaseURL: apiBaseURL) }
        inFlight = task
        let version = await task.value
        inFlight = nil
        if let version { cached = (version, clock.now) }
        return version
    }

    private static func fetch(session: URLSession, apiBaseURL: URL) async -> String? {
        var request = URLRequest(url: apiBaseURL.appending(path: "repos/\(repository)/releases/latest"))
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let release = try? JSONDecoder().decode(Release.self, from: data),
            release.tagName.hasPrefix(tagPrefix)
        else { return nil }
        let version = String(release.tagName.dropFirst(tagPrefix.count))
        return HostServiceVersion(version) == nil ? nil : version
    }

    private struct Release: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }
}
