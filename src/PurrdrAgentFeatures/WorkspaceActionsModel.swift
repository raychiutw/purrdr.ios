import Foundation
import Observation
import PurrdrCore

/// 列表列的操作(行為規格 F2.7、F3.4、F3.5):釘選、靜音聊天;重新命名、關閉 workspace;從 workspace 建立 git worktree。
///
/// 成功改到主機的操作之後呼叫 `refresh` 重讀列表(herdr 可能正規化或拒絕名稱，以主機為準)。
@MainActor
@Observable
public final class WorkspaceActionsModel {
    /// 本機的釘選與靜音。
    public private(set) var preferences: ChatPreferences
    /// 重新命名失敗的原因，顯示在重新命名表單裡。
    public private(set) var renameError: String?
    /// 建立 worktree 失敗的原因，顯示在表單裡。
    public private(set) var worktreeError: String?
    /// 關閉等已結束的動作失敗時的訊息，以可關閉的橫幅顯示(與連線錯誤分開)。
    public var actionError: String?
    /// 有操作正在主機上執行。
    public private(set) var isWorking = false
    /// 這支裝置配對成唯讀(HTTPS 主機):改到主機的操作停用(`loadAccess()` 讀)。
    public private(set) var isReadOnly = false
    private var accessLoaded = false
    /// 靜音清單改變時呼叫(推播開著時改寫主機上的靜音清單,#29)。
    public var mutedChanged: (@MainActor (Set<String>) -> Void)?

    private let client: HerdrClient
    private let store: any ChatPreferencesStore
    private let now: @Sendable () -> Date
    private let refresh: @MainActor () async -> Void

    public init(
        client: HerdrClient, preferences store: any ChatPreferencesStore,
        now: @escaping @Sendable () -> Date = { Date() },
        refresh: @escaping @MainActor () async -> Void = {}
    ) {
        self.client = client
        self.store = store
        self.now = now
        self.refresh = refresh
        preferences = store.load()
    }

    /// 唯讀裝置不能改名、關閉或建立 worktree 的說明。
    public static let readOnlyMessage = HostErrorText.hostServiceMessage(.readOnlyDevice)

    /// 讀一次這支裝置是否唯讀(HTTPS 主機握手時回報;SSH 主機一律可寫)。
    public func loadAccess() async {
        guard !accessLoaded else { return }
        accessLoaded = true
        isReadOnly = (try? await client.isReadOnlyDevice()) == true
    }

    // MARK: - 釘選、靜音

    public func isPinned(sessionID: String) -> Bool { preferences.pinned[sessionID] != nil }
    public func isMuted(sessionID: String) -> Bool { preferences.muted.contains(sessionID) }

    public func togglePin(sessionID: String) {
        preferences.pinned[sessionID] = isPinned(sessionID: sessionID) ? nil : now()
        store.save(preferences)
    }

    /// 記下開啟這個 session 聊天的時間(進入與離開對話時各一次;行為規格 F2.6)。之前的回覆都算讀過。
    /// - Parameter seen: 開著時看到的最後一則回覆的時間(主機時間)。主機時鐘比手機快時，回覆時間會在手機的「現在」之後;
    ///   取兩者較晚的，開過的聊天才不會一直是未讀。
    public func markOpened(sessionID: String, seen: Date? = nil) {
        preferences.opened[sessionID] = max(now(), seen ?? .distantPast)
        store.save(preferences)
    }

    public func toggleMute(sessionID: String) {
        if preferences.muted.remove(sessionID) == nil { preferences.muted.insert(sessionID) }
        store.save(preferences)
        mutedChanged?(preferences.muted)
    }

    // MARK: - 重新命名

    /// 修剪後非空且不同於原名稱才可儲存(行為規格 F3.4)。
    public static func canRename(from original: String, to label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != original
    }

    /// 重新命名 workspace。成功回 `true` 並重讀列表;失敗時原因放在 `renameError`。
    public func rename(workspaceID: String, to label: String) async -> Bool {
        renameError = nil
        return await perform {
            try await client.renameWorkspace(workspaceID, to: label.trimmingCharacters(in: .whitespacesAndNewlines))
        } onError: {
            renameError = $0
        }
    }

    /// 重新命名 tab(#456)。成功回 `true` 並重讀列表;失敗時原因放在 `renameError`。
    public func renameTab(tabID: String, to label: String) async -> Bool {
        renameError = nil
        return await perform {
            try await client.renameTab(tabID, to: label.trimmingCharacters(in: .whitespacesAndNewlines))
        } onError: {
            renameError = $0
        }
    }

    public func clearRenameError() { renameError = nil }

    // MARK: - 關閉

    /// 同 repo 的 worktree workspace 還開著，herdr 拒絕關閉。
    public static let groupCloseRequiredMessage =
        String(localized: "This repo’s worktree workspaces are still open. Close them first.")

    /// 關閉 workspace。成功後清掉它的聊天(`sessionIDs`)在本機的釘選與靜音，並重讀列表;失敗時原因放在 `actionError`。
    public func close(workspaceID: String, sessionIDs: [String]) async {
        actionError = nil
        let closed = await perform {
            try await client.closeWorkspace(workspaceID)
        } onError: {
            actionError = $0
        }
        guard closed else { return }
        for sessionID in sessionIDs {
            preferences.pinned[sessionID] = nil
            preferences.muted.remove(sessionID)
            preferences.opened[sessionID] = nil
        }
        store.save(preferences)
    }

    // MARK: - worktree

    /// workspace 的資料夾不在 git repo 裡。
    public static let notGitRepoMessage =
        String(localized: "This workspace’s folder isn’t in a git repo, so a worktree can’t be created.")

    /// 以 workspace 所在的 repo 建立 worktree 與分支。成功回傳新 workspace 並重讀列表;失敗時原因放在 `worktreeError`。
    public func createWorktree(from workspaceID: String, branch: String) async -> CreatedWorkspace? {
        worktreeError = nil
        var created: CreatedWorkspace?
        _ = await perform {
            created = try await client.createWorktree(from: workspaceID, branch: branch.trimmingCharacters(in: .whitespacesAndNewlines))
        } onError: {
            worktreeError = $0
        }
        return created
    }

    public func clearWorktreeError() { worktreeError = nil }

    // MARK: -

    private func perform(_ operation: () async throws -> Void, onError: (String) -> Void) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            onError(Self.message(for: error))
            return false
        }
        await refresh()
        return true
    }

    /// 需要另外說明的碼換成使用者看得懂的話;其他保留 herdr 原文(行為規格 §3.8)。
    package static func message(for error: any Error) -> String {
        switch error {
        case HerdrError.herdr(code: "workspace_group_close_required", _): groupCloseRequiredMessage
        case HerdrError.herdr(code: "not_git_worktree", _): notGitRepoMessage
        case HerdrError.herdr(_, let message): message
        // HTTPS 主機：主機服務版本不足、唯讀裝置等(#287)。
        case let error as HostServiceError: HostErrorText.hostServiceMessage(error)
        default: String(localized: "Couldn’t reach your agents on this host. Make sure herdr is running there.")
        }
    }
}
