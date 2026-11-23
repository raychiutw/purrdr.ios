import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH

/// 檔案瀏覽(行為規格 F13):列出主機的資料夾(從家目錄開始)、打開資料夾、上一層、上傳檔案到目前的資料夾。
///
/// 每檔上限 25 MB:上傳前先看檔案大小，超過就不讀檔、不送指令。
@MainActor
@Observable
public final class FolderBrowserModel {
    public enum Phase: Equatable {
        case loading
        case loaded(FolderListing)
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    /// 目前的資料夾(主機上的絕對路徑);還沒列出家目錄時是 `nil`。
    public private(set) var path: String?
    /// 上傳中的檔名。
    public private(set) var uploading: String?
    /// 一次性的提示(上傳失敗、檔案太大)。
    public var notice: String?
    public let hostName: String
    /// 頂列搜尋欄的字串(#500):只比對目前資料夾的項目名稱;換資料夾就清掉。
    public var query = ""

    /// 家目錄(第一次列出的資料夾):麵包屑以「~」代表。
    private var home: String?

    private let folders: HostFolders
    /// 每次載入加一;晚到的舊結果丟棄。
    private var generation = 0

    private let skeletonRowCounts: any SkeletonRowCountStore

    public init(
        folders: HostFolders, hostName: String, skeletonRowCounts: any SkeletonRowCountStore = InMemorySkeletonRowCountStore()
    ) {
        self.folders = folders
        self.hostName = hostName
        self.skeletonRowCounts = skeletonRowCounts
    }

    public var isSearching: Bool { !trimmedQuery.isEmpty }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 目前資料夾要顯示的項目:沒搜尋是全部,有搜尋是名稱含搜尋字串的(不分大小寫)。
    public var visibleEntries: [FolderEntry] {
        guard case .loaded(let listing) = phase else { return [] }
        guard isSearching else { return listing.entries }
        return listing.entries.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    /// 載入骨架的列數:取上次列出的項目數(#496)。
    public var loadingRowCount: Int { SkeletonLoading.rowCount(lastCount: skeletonRowCounts.load(.files)) }

    /// 資料夾最後一段;根目錄是「/」(Windows 是「C:\」)。路徑依主機的語法切段(#26)。
    public var title: String {
        guard let path else { return String(localized: "Files") }
        return HostPathSyntax.isRoot(path) ? path : (HostPathSyntax.lastComponent(path).map(String.init) ?? path)
    }

    public var canGoUp: Bool { navigation.canGoUp }

    /// 路徑麵包屑(#273,原型 purrdr-screens 定案版:「~ › Projects › ledger」):由上而下每一層一段，最後一段是目前的資料夾。
    /// 家目錄與它底下以「~」開頭;家目錄外從根目錄(`/`、`C:\`)開始。路徑依主機的語法切段(#26)。
    public var breadcrumbs: [FolderBreadcrumb] { FolderBreadcrumb.trail(to: path, home: home) }

    /// 點麵包屑的一段：打開那一層。
    public func go(to crumb: FolderBreadcrumb) async {
        guard crumb.path != path else { return }
        await list(crumb.path)
    }

    private var navigation: FolderNavigation { FolderNavigation(current: path) }

    /// 重新載入目前的資料夾(一開始是家目錄)。
    public func load() async {
        await list(path)
    }

    /// 打開資料夾或 symlink(指向資料夾才打得開);檔案不能打開。
    public func open(_ entry: FolderEntry) async {
        guard entry.kind == .folder || entry.kind == .symlink, let child = navigation.child(entry.name) else { return }
        await list(child)
    }

    public func goUp() async {
        guard let parent = navigation.parent else { return }
        await list(parent)
    }

    private func list(_ target: String?) async {
        generation += 1
        let generation = generation
        // 重新整理已經列出的同一個資料夾:留著原本的列,不退回骨架(#496)。
        let isRefresh: Bool
        if case .loaded = phase, target == path { isRefresh = true } else { isRefresh = false }
        if !isRefresh { phase = .loading; query = "" }
        do {
            let listing = try await folders.list(target)
            guard self.generation == generation else { return }
            if !listing.entries.isEmpty { skeletonRowCounts.save(listing.entries.count, for: .files) }
            if target == nil, home == nil { home = listing.path }
            path = listing.path
            phase = .loaded(listing)
        } catch {
            guard self.generation == generation else { return }
            if let target { path = target }
            phase = .failed(Self.message(for: error))
        }
    }

    // MARK: - 上傳

    /// 上傳文件挑選器選到的檔案(先看大小，超過上限就不讀)。
    public func upload(fileAt url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            notice = String(localized: "Couldn’t read this file.")
            return
        }
        guard size <= HostFolders.maximumUploadSize else {
            notice = Self.message(for: HostFolderError.tooLarge)
            return
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            notice = String(localized: "Couldn’t read this file.")
            return
        }
        await upload(data, named: name)
    }

    /// 上傳到目前的資料夾，成功後重新整理清單。主機上已有同名項目時拒絕(永不覆寫)。
    public func upload(_ data: Data, named name: String) async {
        guard let path, uploading == nil else { return }
        uploading = name
        defer { uploading = nil }
        do {
            _ = try await folders.upload(data, named: name, to: path)
        } catch HostFolderError.alreadyExists {
            notice = String(localized: "There’s already an item named “\(name)” in this folder. Rename the file and try again.")
            return
        } catch {
            notice = Self.message(for: error)
            return
        }
        await list(path)
    }

    static func message(for error: any Error) -> String {
        switch error {
        case HostFolderError.notAFolderListing:
            String(localized: "The host didn’t respond with a folder listing.")
        case HostFolderError.cannotOpen(let detail):
            detail.isEmpty
                ? String(localized: "Couldn’t open this folder.")
                : String(localized: "Couldn’t open this folder. \(detail)")
        case HostFolderError.tooLarge:
            String(localized: "Files over 25 MB can’t be uploaded.")
        case HostFolderError.invalidName:
            String(localized: "This file name can’t be used on the host.")
        case HostFolderError.alreadyExists:
            String(localized: "There’s already an item with this name in this folder.")
        case HostFolderError.interrupted, HostFolderError.deadlineExceeded:
            String(localized: "The upload was interrupted. Nothing was saved on the host.")
        case HostFolderError.unexpectedPath:
            String(localized: "The host saved the file somewhere unexpected.")
        case HostFolderError.failed(_, let detail):
            detail.isEmpty
                ? String(localized: "The host couldn’t save the file.")
                : String(localized: "The host couldn’t save the file. \(detail)")
        default:
            HostErrorText.message(for: error)
        }
    }
}

/// 檔案頁路徑麵包屑的一段：顯示的名稱與那一層的路徑。
public struct FolderBreadcrumb: Equatable, Hashable, Sendable {
    public var title: String
    public var path: String
    /// 家目錄(顯示「~」,VoiceOver 念「家目錄」)。
    public var isHome: Bool

    public init(title: String, path: String, isHome: Bool = false) {
        self.title = title
        self.path = path
        self.isHome = isHome
    }

    /// 從根目錄(或家目錄)到 `path` 的每一層;家目錄與它底下以「~」開頭。檔案頁與資料夾瀏覽共用。
    static func trail(to path: String?, home: String?) -> [FolderBreadcrumb] {
        guard let path else { return [] }
        var chain = [path]
        while let parent = HostPathSyntax.parent(of: chain[0]) { chain.insert(parent, at: 0) }
        if let home, let start = chain.firstIndex(of: home) {
            return [FolderBreadcrumb(title: "~", path: home, isHome: true)] + chain[(start + 1)...].map(crumb)
        }
        return chain.map(crumb)
    }

    private static func crumb(_ path: String) -> FolderBreadcrumb {
        let title = HostPathSyntax.isRoot(path) ? path : (HostPathSyntax.lastComponent(path).map(String.init) ?? path)
        return FolderBreadcrumb(title: title, path: path)
    }
}
