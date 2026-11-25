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
    /// 選填:workspace 與第一個 tab 的名稱(#532);留空沿用資料夾名與預設。
    public var workspaceName = ""
    public var tabName = ""
    public var agent: AgentID = .claude {
        didSet { if agent != oldValue { choice = .new } }
    }
    /// agent 就緒後送出的第一則訊息。
    public var message = ""
    /// agent 停在啟動問題時沒送出的第一則訊息(開聊天時放進輸入框)。
    public private(set) var unsentMessage: String?
    public private(set) var isStarting = false
    /// 開始失敗的原因(顯示在表單裡)。
    public private(set) var error: String?
    /// 唯讀裝置不能新增聊天的說明(`loadAccess()` 讀到唯讀時才有)。
    public private(set) var readOnlyReason: String?

    /// 清單的選擇(#309):只有一個勾號，第一列是全新的聊天，其餘是過去的 session。
    public enum Choice: Hashable, Sendable {
        case new
        case resume(String)
    }

    /// 這個資料夾過去的 session 清單狀態。
    public enum SessionsState: Equatable {
        /// 還沒有資料夾、這個 agent 不能續接，或還沒讀。
        case idle
        case loading
        /// 新到舊;空陣列表示沒有過去的 session(清單只有「新的聊天」)。
        case loaded([ResumableSession])
        /// 主機服務版本不足:畫面附更新指令。
        case updateRequired(HostServiceUpdateCommands)
        case failed(String)
    }

    public var choice: Choice = .new

    /// 放在哪裡(#537):新的 Workspace(預設)或既有的。
    public enum Placement: Hashable, Sendable {
        case newWorkspace
        case existing(String)
    }

    public var placement: Placement = .newWorkspace {
        didSet { if placement != oldValue { choice = .new } }
    }

    /// 這台主機目前開著的 Workspace(`loadWorkspaces()` 讀到的)。
    public private(set) var workspaces: [ExistingWorkspace] = []
    /// 這台主機能不能在既有 Workspace 新增 Tab(HTTPS 主機服務要 0.15.0 起才有 `tab.create`;`HostsModel.supportsNewChatInWorkspace` 判斷)。
    private let supportsExistingWorkspaces: Bool
    public private(set) var sessions: SessionsState = .idle

    private let launcher: NewChatLauncher
    private let folders: NewChatFolders
    /// 讀過的續接支援(整個表單只問一次)。
    private var resumeSupport: ResumeSupport?

    /// 新增聊天選單要列的 Agent:只有這台主機啟用的(#477,`HostAgentSettings`)。
    public let availableAgents: [AgentID]

    public init(
        launcher: NewChatLauncher, folders: NewChatFolders,
        agents: [AgentID] = HostAgentSettings.newChatAgents(enabled: HostAgentSettings.previouslyShownUsage),
        supportsExistingWorkspaces: Bool = true
    ) {
        self.supportsExistingWorkspaces = supportsExistingWorkspaces
        self.launcher = launcher
        self.folders = folders
        availableAgents = agents
        agent = agents.first ?? .claude
    }

    private var trimmedFolder: String {
        // 既有 Workspace:沿用它的工作目錄(續接過去的聊天要用它)。
        if let selectedWorkspace { return selectedWorkspace.folder ?? "" }
        return folder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 選了的既有 Workspace;`placement` 是新的 Workspace 時為 `nil`。
    public var selectedWorkspace: ExistingWorkspace? {
        guard case .existing(let id) = placement else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// 有東西可選時畫面才出現「放在哪裡」的選擇。
    public var canChooseExistingWorkspace: Bool { supportsExistingWorkspaces && !workspaces.isEmpty }

    /// 讀這台主機的 Workspace 清單(畫面出現時)。讀不到就沒有選擇,維持新的 Workspace。
    public func loadWorkspaces() async {
        guard supportsExistingWorkspaces else { return }
        workspaces = (try? await launcher.existingWorkspaces()) ?? []
        if let id = preselectedWorkspaceID {
            preselectedWorkspaceID = nil
            selectWorkspace(id)
        }
        // 選的那個已經不在了:回到新的 Workspace。
        if case .existing(let id) = placement, !workspaces.contains(where: { $0.id == id }) { placement = .newWorkspace }
    }

    /// 預選既有 Workspace(Spaces 的「在此新增聊天」);不在清單裡就維持新的 Workspace。
    public func selectWorkspace(_ id: String) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        placement = .existing(id)
        error = nil
    }

    /// 開啟前就指定要放在哪個既有 Workspace(清單還沒讀到時先記著,`loadWorkspaces()` 後套用)。
    public func preselectWorkspace(_ id: String) { preselectedWorkspaceID = id }
    private var preselectedWorkspaceID: String?

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 選了續接。
    public var isResuming: Bool {
        if case .resume = choice { return true }
        return false
    }

    /// 續接時第一則訊息可以留空;全新的聊天一定要有。
    public var canStart: Bool {
        !availableAgents.isEmpty && (selectedWorkspace != nil || !trimmedFolder.isEmpty) && (isResuming || !trimmedMessage.isEmpty) && !isStarting && readOnlyReason == nil
    }

    /// 讀清單的條件變了(資料夾或 agent)就重讀;畫面以它當 `.task(id:)`。
    public var sessionsKey: String { "\(agent.canonicalName)|\(trimmedFolder)" }

    /// 讀這個資料夾過去的 session(#309)。換了資料夾或 agent 時選擇回到「新的聊天」。
    public func refreshSessions() async {
        choice = .new
        guard agent.supportsResume, !trimmedFolder.isEmpty else {
            sessions = .idle
            return
        }
        let folder = trimmedFolder
        let agent = agent
        let support: ResumeSupport
        if let resumeSupport {
            support = resumeSupport
        } else {
            do {
                support = try await launcher.resumeSupport()
            } catch is CancellationError {
                return
            } catch {
                // 連不上不等於「需要主機服務」:說明原因、不記住,按「再試一次」或換資料夾時重讀。
                guard folder == trimmedFolder, agent == self.agent else { return }
                sessions = .failed(Self.message(for: error))
                return
            }
            // 只記住不會變的結果(能續接);版本太舊時使用者更新後要能立刻再讀到。
            if support == .available { resumeSupport = support }
        }
        switch support {
        case .updateRequired(let installed):
            sessions = .updateRequired(HostServiceUpdates.commands(installed: installed ?? "0.0.0"))
        case .available:
            sessions = .loading
            do {
                let found = try await launcher.resumableSessions(folder: folder, agent: agent)
                // 讀的途中資料夾或 agent 又換了:丟掉這份舊結果。
                guard folder == trimmedFolder, agent == self.agent else { return }
                sessions = .loaded(found)
            } catch is CancellationError {
                return
            } catch {
                guard folder == trimmedFolder, agent == self.agent else { return }
                sessions = .failed(Self.message(for: error))
            }
        }
    }

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
        var resumeSession: String?
        if case .resume(let id) = choice { resumeSession = id }
        let request = NewChatRequest(
            folder: trimmedFolder, label: selectedWorkspace == nil ? Self.optional(workspaceName) : nil, tabLabel: Self.optional(tabName), agent: agent,
            message: trimmedMessage, resumeSession: resumeSession, target: selectedWorkspace.map { .existingWorkspace(id: $0.id) } ?? .newWorkspace)
        isStarting = true
        error = nil
        unsentMessage = nil
        defer { isStarting = false }
        do {
            let started = try await launcher.start(request)
            // 續接時訊息可以留空:沒有訊息就沒有「沒送出的訊息」。
            if !started.sentMessage, !trimmedMessage.isEmpty { unsentMessage = trimmedMessage }
            return started.workspace
        } catch {
            self.error = Self.message(for: error)
            return nil
        }
    }

    /// 放棄新增聊天(取消或關掉畫面):主機上建了一半、agent 沒啟動的 Workspace 或 Tab 關掉，不留只有 shell 的 Tab。
    public func discardUnstarted() async {
        await launcher.discardUnstarted()
    }

    private static func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    package static func message(for error: any Error) -> String {
        switch error {
        case NewChatFolderError.notFound, HerdrError.herdr(code: "folder_not_found", _):
            String(localized: "There’s no such folder on the host. Check the location, or choose a folder on the host.")
        case NewChatFolderError.absolutePathRequired:
            String(localized: "Type the folder’s location on the host, like /Users/you/project. This host can’t show a folder list.")
        case NewChatFolderError.unexpectedResponse, NewChatFolderError.failed:
            FolderPickerModel.message(for: error)
        case TranscriptReadError.absent:
            String(localized: "That chat’s record is no longer on the host, so it can’t be resumed. Pick another chat, or start a new one.")
        case HerdrError.herdr(code: "workspace_not_found", _):
            String(localized: "That Workspace was closed on the host. Choose another one, or start a new Workspace.")
        case HerdrError.herdr(code: "demo_unsupported", _):
            String(localized: "The Demo host can’t start new chats. Add your own host to try this.")
        case HerdrError.herdr(_, let message):
            message
        case HerdrError.noResponse, HerdrError.malformedResponse, HerdrError.deadlineExceeded:
            String(localized: "Couldn’t reach your agents on this host. Make sure herdr is running there.")
        default:
            HostErrorText.message(for: error)
        }
    }
}
