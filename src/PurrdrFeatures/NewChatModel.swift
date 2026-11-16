import Foundation
import Observation
import PurrdrCore

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
    public var canGoUp: Bool {
        chosenPath.flatMap(HostPathSyntax.parent(of:)) != nil
    }

    /// 讀 `requested`(第一次或重試)。
    public func load() async {
        await list(requested)
    }

    public func open(_ name: String) async {
        guard let path = chosenPath else { return }
        await list(HostPathSyntax.appending(name, to: path))
    }

    public func goUp() async {
        guard let parent = chosenPath.flatMap(HostPathSyntax.parent(of:)) else { return }
        await list(parent)
    }

    private func list(_ path: String?) async {
        requested = path
        state = .loading
        do {
            let listing = try await folders.list(path)
            state = .loaded(listing)
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    static func message(for error: any Error) -> String {
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

/// 新增對話的表單(行為規格 F3.1;#18):資料夾、名稱、agent、權限模式。
///
/// 權限模式預設沿用 agent 自己的設定，不預設成完全不詢問(`bypassPermissions`)。
@MainActor
@Observable
public final class NewChatModel {
    /// 主機上的資料夾(可以打 `~/…`,或從資料夾瀏覽挑)。
    public var folder = ""
    /// workspace 名稱(選填;空白時由 herdr 用資料夾名)。
    public var name = ""
    public var agent: NewChatAgent = .claude
    public var permissionMode: ClaudePermissionMode = .agentDefault
    public private(set) var isStarting = false
    /// 開始失敗的原因(顯示在表單裡)。
    public private(set) var error: String?

    private let launcher: NewChatLauncher
    private let folders: NewChatFolders

    public init(launcher: NewChatLauncher, folders: NewChatFolders) {
        self.launcher = launcher
        self.folders = folders
    }

    private var trimmedFolder: String { folder.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var canStart: Bool { !trimmedFolder.isEmpty && !isStarting }

    /// 權限模式只有 Claude Code 有。
    public var showsPermissionMode: Bool { agent == .claude }

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
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = NewChatRequest(
            folder: trimmedFolder, label: label.isEmpty ? nil : label, agent: agent,
            permissionMode: agent == .claude ? permissionMode : .agentDefault)
        isStarting = true
        error = nil
        defer { isStarting = false }
        do {
            return try await launcher.start(request)
        } catch {
            self.error = Self.message(for: error)
            return nil
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case NewChatFolderError.notFound:
            String(localized: "There’s no such folder on the host. Check the path, or choose a folder on the host.")
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
