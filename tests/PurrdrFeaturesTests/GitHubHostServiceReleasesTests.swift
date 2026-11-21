import Foundation
import PurrdrFeatures
import PurrdrTestSupport
import Testing

/// 主機服務的最新版本從 raychiutw/purrdr.host 的最新 GitHub Release 取得(#362),不再寫死在 app。
@Suite("主機服務最新版本：GitHub Release(#362)")
struct GitHubHostServiceReleasesTests {
    static let path = "/repos/raychiutw/purrdr.host/releases/latest"

    static func releases(_ github: HTTPStub) -> GitHubHostServiceReleases {
        GitHubHostServiceReleases(session: github.urlSession, apiBaseURL: github.baseURL)
    }

    @Test("最新 Release 的 tag host-service-v<版本> 取出版本號")
    func latestVersionComesFromReleaseTag() async {
        let github = HTTPStub()
        github.on("GET", Self.path, .json(200, #"{"tag_name": "host-service-v0.10.1", "name": "主機服務 0.10.1"}"#))

        let latest = await Self.releases(github).latestVersion()

        #expect(latest == "0.10.1")
        #expect(github.requests(to: Self.path).first?.headers["Accept"] == "application/vnd.github+json")
    }

    @Test("取不到或看不懂(連不上、非 200 即使內容像 Release、tag 格式不同)時回 nil,不誤報新版")
    func unusableAnswersGiveNoVersion() async {
        for reply in [
            HTTPStub.Reply.unreachable, .json(404, #"{"message": "Not Found"}"#), .json(403, #"{"message": "rate limit"}"#),
            .json(500, #"{"tag_name": "host-service-v9.9.9"}"#), .json(200, #"{"tag_name": "v9.9.9"}"#),
            .json(200, #"{"tag_name": "host-service-vnext"}"#), .json(200, "[]"),
        ] {
            let github = HTTPStub()
            github.on("GET", Self.path, reply)

            #expect(await Self.releases(github).latestVersion() == nil)
        }
    }

    @Test("取得的版本快取起來，重複查不再送請求;失敗不快取，下次再試")
    func successIsCachedFailureIsRetried() async {
        let github = HTTPStub()
        github.on("GET", Self.path, .unreachable, .json(200, #"{"tag_name": "host-service-v0.10.1"}"#))
        let releases = Self.releases(github)

        #expect(await releases.latestVersion() == nil)
        #expect(await releases.latestVersion() == "0.10.1")
        #expect(await releases.latestVersion() == "0.10.1")

        #expect(github.requests(to: Self.path).count == 2)
    }

    @Test("快取過期後重新查")
    func expiredCacheIsRefetched() async {
        let github = HTTPStub()
        github.on(
            "GET", Self.path, .json(200, #"{"tag_name": "host-service-v0.10.1"}"#), .json(200, #"{"tag_name": "host-service-v0.11.0"}"#))
        let releases = GitHubHostServiceReleases(session: github.urlSession, apiBaseURL: github.baseURL, cacheDuration: .zero)

        #expect(await releases.latestVersion() == "0.10.1")
        #expect(await releases.latestVersion() == "0.11.0")
    }

    @Test("同時查只送一個請求")
    func concurrentChecksShareOneRequest() async {
        let github = HTTPStub()
        github.on("GET", Self.path, .json(200, #"{"tag_name": "host-service-v0.10.1"}"#))
        let releases = Self.releases(github)

        async let first = releases.latestVersion()
        async let second = releases.latestVersion()
        async let third = releases.latestVersion()

        #expect(await [first, second, third] == ["0.10.1", "0.10.1", "0.10.1"])
        #expect(github.requests(to: Self.path).count == 1)
    }
}
