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
    /// `actionError` 的標題,寫明失敗的是哪個動作(#625)。
    public private(set) var actionErrorTitle = ""
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

    /// 一個 Tab 底下所有 Agent 一起釘選(Spaces 的 Tab 列,可能有多個 Agent):空的不算釘選;
    /// 有任何一個沒釘就全部釘上(已釘的保留原時間),全部都釘了才全部取消。
    public func arePinned(sessionIDs: [String]) -> Bool { !sessionIDs.isEmpty && sessionIDs.allSatisfy(isPinned(sessionID:)) }

    public func togglePin(sessionIDs: [String]) {
        guard !sessionIDs.isEmpty else { return }
        if arePinned(sessionIDs: sessionIDs) {
            for id in sessionIDs { preferences.pinned[id] = nil }
        } else {
            for id in sessionIDs where preferences.pinned[id] == nil { preferences.pinned[id] = now() }
        }
        store.save(preferences)
    }

    public func areMuted(sessionIDs: [String]) -> Bool { !sessionIDs.isEmpty && sessionIDs.allSatisfy(isMuted(sessionID:)) }

    /// 規則同 `togglePin(sessionIDs:)`;靜音清單只通知一次。
    public func toggleMute(sessionIDs: [String]) {
        guard !sessionIDs.isEmpty else { return }
        if areMuted(sessionIDs: sessionIDs) {
            preferences.muted.subtract(sessionIDs)
        } else {
            preferences.muted.formUnion(sessionIDs)
        }
        store.save(preferences)
        mutedChanged?(preferences.muted)
    }

    /// 記下開啟這個 session 聊天的時間(進入與離開對話時各一次;行為規格 F2.6)。之前的回覆都算讀過。
    /// - Parameter seen: 開著時看到的最後一則回覆的時間(主機時間)。主機時鐘比手機快時，回覆時間會在手機的「現在」之後;
    ///   取兩者較晚的，開過的聊天才不會一直是未讀。
    /// - Parameter liveSessions: 主機快照裡現有的 session;給了才順便修剪 `opened`(見 `ChatPreferences.pruneOpened`)。
    public func markOpened(sessionID: String, seen: Date? = nil, liveSessions: Set<String>? = nil) {
        let current = now()
        preferences.opened[sessionID] = max(current, seen ?? .distantPast)
        if let liveSessions { preferences.pruneOpened(liveSessions: liveSessions.union([sessionID]), now: current) }
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
            actionErrorTitle = String(localized: "Couldn’t Close Workspace")
            actionError = $0
        }
        guard closed else { return }
        forget(sessionIDs)
    }

    private func forget(_ sessionIDs: [String]) {
        for sessionID in sessionIDs {
            preferences.pinned[sessionID] = nil
            preferences.muted.remove(sessionID)
            preferences.opened[sessionID] = nil
        }
        store.save(preferences)
    }

    /// 剛關閉的 Tab 記多久(秒):這段時間內列表先拿掉它，不等重讀列表追上。
    public static let recentlyClosedGrace: TimeInterval = 60

    /// 剛關閉的 Tab 與關閉時間(只在記憶體)。
    private var closedTabs: [String: Date] = [:]

    /// 這個 Tab 是不是剛關閉(還在記住的時間內):列表先拿掉它，不等重讀到的快照追上(SSH 重讀慢時，
    /// 關了列還在、使用者再關一次就得到 tab not found)。過了時限一律以主機的快照為準。
    public func isRecentlyClosed(tabID: String) -> Bool {
        guard let closedAt = closedTabs[tabID] else { return false }
        return now().timeIntervalSince(closedAt) < Self.recentlyClosedGrace
    }

    /// 關閉 tab。成功後清掉它的聊天(`sessionIDs`)在本機的釘選與靜音,並重讀列表;失敗時原因放在 `actionError`。
    /// 是 workspace 最後一個 tab 時 herdr 會連 workspace 一起關(列表重讀後自然反映)。
    public func closeTab(tabID: String, sessionIDs: [String]) async {
        actionError = nil
        let closed = await perform {
            do {
                try await client.closeTab(tabID)
            } catch HerdrError.herdr(code: "tab_not_found", _) {
                // 主機上已經沒有這個 Tab(先前的關閉已成功、或桌機關掉了):目的已達成，當成關閉成功。
            }
            closedTabs[tabID] = now()
        } onError: {
            actionErrorTitle = String(localized: "Couldn’t Close Tab")
            actionError = $0
        }
        guard closed else { return }
        forget(sessionIDs)
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
