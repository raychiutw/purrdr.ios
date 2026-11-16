import Foundation
import Observation
import PurrdrCore

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

    private let folders: HostFolders
    /// 每次載入加一;晚到的舊結果丟棄。
    private var generation = 0

    public init(folders: HostFolders, hostName: String) {
        self.folders = folders
        self.hostName = hostName
    }

    /// 資料夾最後一段;根目錄是「/」。
    public var title: String {
        guard let path else { return String(localized: "Files") }
        return path == "/" ? "/" : (path.split(separator: "/").last.map(String.init) ?? path)
    }

    public var canGoUp: Bool { parent != nil }

    private var parent: String? {
        guard let path, path != "/" else { return nil }
        let components = path.split(separator: "/")
        return components.count <= 1 ? "/" : "/" + components.dropLast().joined(separator: "/")
    }

    /// 重新載入目前的資料夾(一開始是家目錄)。
    public func load() async {
        await list(path)
    }

    /// 打開資料夾或 symlink(指向資料夾才打得開);檔案不能打開。
    public func open(_ entry: FolderEntry) async {
        guard entry.kind == .folder || entry.kind == .symlink, let path else { return }
        await list(path == "/" ? "/" + entry.name : path + "/" + entry.name)
    }

    public func goUp() async {
        guard let parent else { return }
        await list(parent)
    }

    private func list(_ target: String?) async {
        generation += 1
        let generation = generation
        phase = .loading
        do {
            let listing = try await folders.list(target)
            guard self.generation == generation else { return }
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
