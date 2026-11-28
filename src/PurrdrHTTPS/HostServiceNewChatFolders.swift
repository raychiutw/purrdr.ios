import Foundation
import PurrdrCore

/// HTTPS 主機的資料夾瀏覽(主機服務 0.12.0 起,#731):`directory.list` 與 `welcome.home_directory`。
/// `~` 在這裡展開(主機服務只收絕對路徑);版本不足時 `browsingAvailability()` 說明。
public struct HostServiceNewChatFolders: NewChatFolderBrowsing {
    private let browser: any DirectoryBrowsing

    public init(browser: any DirectoryBrowsing) {
        self.browser = browser
    }

    /// 要先過 `browsingAvailability()` 查版本。
    public var canBrowse: Bool { false }

    public func browsingAvailability() async -> NewChatFolderBrowsingAvailability {
        guard let version = try? await browser.hostServiceVersion() else { return .unknown }
        return HostServiceFeature.directoryBrowsing.isAvailable(onHostServiceVersion: version)
            ? .available : .hostServiceUpdateRequired(installedVersion: version)
    }

    public func list(_ path: String?) async throws -> NewChatFolderListing {
        let requested = path.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let target = try await expandingHome(requested.isEmpty ? "~" : requested) ?? requested
        let result = try await browser.listDirectory(path: target)
        // 與 SSH 一致:不列隱藏資料夾,不分大小寫排序。
        let folders = NewChatFolderListing.sorted(result.directories.filter { !$0.isEmpty && !$0.hasPrefix(".") })
        return NewChatFolderListing(path: result.path, folders: folders)
    }

    /// 只展開 `~`;資料夾存不存在由主機服務在建立 workspace 時檢查。
    public func resolve(_ path: String) async throws -> String {
        do {
            if let expanded = try await expandingHome(path) { return expanded }
        } catch NewChatFolderError.homeUnavailable {
            throw NewChatFolderError.absolutePathRequired(path)
        }
        guard HostPathSyntax.isAbsolute(path) else { throw NewChatFolderError.absolutePathRequired(path) }
        return path
    }

    /// `~` 與 `~/…` 換成家目錄;不是 `~` 開頭回 `nil`。唯一的展開處。
    private func expandingHome(_ path: String) async throws -> String? {
        guard path == "~" || path.hasPrefix("~/") else { return nil }
        guard let home = try await browser.homeDirectory(), !home.isEmpty else { throw NewChatFolderError.homeUnavailable }
        let rest = String(path.dropFirst(2))
        guard !rest.isEmpty else { return home }
        let separator = home.hasSuffix("/") || home.hasSuffix("\\") ? "" : "/"
        return home + separator + rest
    }
}
