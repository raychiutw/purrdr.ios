import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH

/// 新增對話的資料夾瀏覽(行為規格 F3.3):在主機上一層層挑資料夾。
///
/// 讀取錯誤與空資料夾是不同狀態(舊版把每個失敗都顯示成「沒有子資料夾」):錯誤有說明與重試，空資料夾是正常的清單。
@MainActor
@Observable
public final class FolderPickerModel {
    public enum State: Equatable {
        case loading
        case loaded(NewChatFolderListing)
        case failed(String)
    }

    public private(set) var state: State = .loading
    /// 一開始要列的資料夾(`nil` = 家目錄)。
    public let startPath: String?

    private let folders: NewChatFolders
    /// 正在讀或上次讀失敗的資料夾(重試讀它)。
    private var requested: String?
    /// 家目錄(從家目錄開始時第一次列出的資料夾):麵包屑以「~」代表。
    private var home: String?

    public init(folders: NewChatFolders, start: String?) {
        self.folders = folders
        startPath = start
        requested = start
    }

    /// 「使用這個資料夾」的值：目前列出的資料夾;還沒讀到或讀失敗時為 `nil`。
    public var chosenPath: String? {
        if case .loaded(let listing) = state { return listing.path }
        return nil
    }

    /// 在根目錄(`/`、`C:\`)或還沒讀到時不能往上。
    public var canGoUp: Bool { navigation.canGoUp }

    private var navigation: FolderNavigation { FolderNavigation(current: chosenPath) }

    /// 讀 `requested`(第一次或重試)。
    public func load() async {
        await list(requested)
    }

    public func open(_ name: String) async {
        guard let child = navigation.child(name) else { return }
        await list(child)
    }

    public func goUp() async {
        guard let parent = navigation.parent else { return }
        await list(parent)
    }

    /// 路徑麵包屑(比照檔案頁，實機回報 2026-11-20)。
    public var breadcrumbs: [FolderBreadcrumb] { FolderBreadcrumb.trail(to: chosenPath, home: home) }

    /// 點麵包屑的一段：打開那一層。
    public func go(to crumb: FolderBreadcrumb) async {
        guard crumb.path != chosenPath else { return }
        await list(crumb.path)
    }

    private func list(_ path: String?) async {
        requested = path
        state = .loading
        do {
            let listing = try await folders.list(path)
            if path == nil || path?.isEmpty == true, home == nil { home = listing.path }
            state = .loaded(listing)
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    package static func message(for error: any Error) -> String {
        switch error {
        case NewChatFolderError.notFound:
            String(localized: "This folder isn’t on the host, or you can’t open it.")
        case NewChatFolderError.unexpectedResponse:
            String(localized: "The host didn’t answer with a list of folders.")
        case NewChatFolderError.failed:
            String(localized: "Couldn’t read this folder on the host.")
        default:
            HostErrorText.message(for: error)
        }
    }
}

/// 新增對話的表單(#272,原型 purrdr-screens 定案版):主機(畫面的標題列)、agent、資料夾、第一則訊息。
///
/// 名稱由 herdr 用資料夾名;權限模式沿用 agent 自己的設定，不預設成完全不詢問(`bypassPermissions`)。
@MainActor
@Observable
public final class NewChatModel {
    /// 主機上的資料夾(可以打 `~/…`,或從資料夾瀏覽挑)。
    public var folder = ""
    public var agent: NewChatAgent = .claude
    /// agent 就緒後送出的第一則訊息。
    public var message = ""
    /// agent 停在啟動問題時沒送出的第一則訊息(開聊天時放進輸入框)。
    public private(set) var unsentMessage: String?
    public private(set) var isStarting = false
    /// 開始失敗的原因(顯示在表單裡)。
    public private(set) var error: String?
    /// 唯讀裝置不能新增聊天的說明(`loadAccess()` 讀到唯讀時才有)。
    public private(set) var readOnlyReason: String?

    private let launcher: NewChatLauncher
    private let folders: NewChatFolders

    public init(launcher: NewChatLauncher, folders: NewChatFolders) {
        self.launcher = launcher
        self.folders = folders
    }

    private var trimmedFolder: String { folder.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var canStart: Bool { !trimmedFolder.isEmpty && !trimmedMessage.isEmpty && !isStarting && readOnlyReason == nil }

    /// 能不能在主機上瀏覽資料夾(HTTPS 主機不能，要輸入完整路徑)。
    public var canBrowseFolders: Bool { folders.canBrowse }

    /// 讀這支裝置是否唯讀(HTTPS 主機握手時回報)。
    public func loadAccess() async {
        readOnlyReason = await launcher.isReadOnlyDevice() ? HostErrorText.message(for: HostServiceError.readOnlyDevice) : nil
    }

    /// 資料夾瀏覽，從表單目前的資料夾開始(空白 = 家目錄)。
    public func makeFolderPicker() -> FolderPickerModel {
        FolderPickerModel(folders: folders, start: trimmedFolder.isEmpty ? nil : trimmedFolder)
    }

    /// 資料夾瀏覽按了「使用這個資料夾」。
    public func choose(_ path: String) {
        folder = path
        error = nil
    }

    /// 開始。成功回傳新 workspace(聊天開在它的 root pane);失敗時原因放在 `error`。
    public func start() async -> CreatedWorkspace? {
        guard canStart else { return nil }
        let request = NewChatRequest(folder: trimmedFolder, agent: agent, message: trimmedMessage)
        isStarting = true
        error = nil
        unsentMessage = nil
        defer { isStarting = false }
        do {
            let started = try await launcher.start(request)
            if !started.sentMessage { unsentMessage = trimmedMessage }
            return started.workspace
        } catch {
            self.error = Self.message(for: error)
            return nil
        }
    }

    package static func message(for error: any Error) -> String {
        switch error {
        case NewChatFolderError.notFound, HerdrError.herdr(code: "folder_not_found", _):
            String(localized: "There’s no such folder on the host. Check the path, or choose a folder on the host.")
        case NewChatFolderError.absolutePathRequired:
            String(localized: "Enter the folder’s full path on the host, like /Users/you/project. This host can’t browse folders.")
        case NewChatFolderError.unexpectedResponse, NewChatFolderError.failed:
            FolderPickerModel.message(for: error)
        case HerdrError.herdr(code: "demo_unsupported", _):
            String(localized: "The Demo host can’t start new chats. Add your own host to try this.")
        case HerdrError.herdr(_, let message):
            message
        case HerdrError.noResponse, HerdrError.malformedResponse, HerdrError.deadlineExceeded:
            String(localized: "Couldn’t reach herdr on this host.")
        default:
            HostErrorText.message(for: error)
        }
    }
}
