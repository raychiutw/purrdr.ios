import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore

/// 主機清單的變更(新增、修改、刪除)要通知誰。`HostsModel` 在使用者改動主機時呼叫;主機同步據此記下修改並上傳。
@MainActor
public protocol HostChangeRecorder: AnyObject {
    func hostSaved(_ id: UUID)
    func hostDeleted(_ id: UUID)
}

/// 主機同步的本機狀態：是否開啟、修改紀錄(只有 id 與時間，沒有主機內容與祕密)。
@MainActor
public protocol HostSyncStore: AnyObject {
    var isEnabled: Bool { get set }
    var journal: HostSyncJournal { get set }
}

@MainActor
public final class InMemoryHostSyncStore: HostSyncStore {
    public var isEnabled = false
    public var journal = HostSyncJournal()

    public init() {}
}

/// 存在 UserDefaults(`hostSync.enabled`、`hostSync.journal`)。
@MainActor
public final class UserDefaultsHostSyncStore: HostSyncStore {
    static let enabledKey = "hostSync.enabled"
    static let journalKey = "hostSync.journal"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    public var journal: HostSyncJournal {
        get {
            defaults.data(forKey: Self.journalKey).flatMap { try? JSONDecoder().decode(HostSyncJournal.self, from: $0) } ?? HostSyncJournal()
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.journalKey) }
    }
}

/// 主機同步(GLOSSARY「主機同步」、ADR-0007):會員主動開啟，主機名稱、位址、使用者、連線方式、host key 指紋、主機圖示
/// 在會員的各裝置間同步。以單一主機為單位最後修改者勝(後台判定);刪除留紀錄、不被同步回來;私鑰與密碼永不上傳。
///
/// 要有 Purrdr Plus(`SubscriptionModel.isPlusActive`):沒有就不開啟;開啟後到期就停止同步並提示續訂。
@MainActor
@Observable
public final class HostSyncModel: HostChangeRecorder {
    public enum Status: Equatable, Sendable {
        case off
        case syncing
        case upToDate(Date)
        /// 沒有 Purrdr Plus(沒登入、沒訂閱或已到期):不同步。
        case needsPlus
        case failed(String)
    }

    public private(set) var isEnabled: Bool
    public private(set) var status: Status = .off

    private let session: MemberSession
    private let plus: SubscriptionModel
    private let hosts: HostsModel
    private let store: any HostSyncStore
    private let now: @MainActor () -> Date

    public init(
        session: MemberSession, plus: SubscriptionModel, hosts: HostsModel, store: any HostSyncStore,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.session = session
        self.plus = plus
        self.hosts = hosts
        self.store = store
        self.now = now
        isEnabled = store.isEnabled
        hosts.changeRecorder = self
    }

    /// 開啟或關閉主機同步。開啟前確認 Purrdr Plus(沒有就不開，提示訂閱);關閉時後台的資料保留。
    public func setEnabled(_ enabled: Bool) async {
        guard enabled else {
            isEnabled = false
            store.isEnabled = false
            status = .off
            return
        }
        await plus.refresh()
        guard plus.isPlusActive else {
            status = .needsPlus
            return
        }
        isEnabled = true
        store.isEnabled = true
        await sync()
    }

    /// 同步一次(開啟時):上傳這支裝置還沒上傳的修改與刪除，再把後台的結果併回來。
    /// 同步中又被要求同步時，做完這次再做一次。
    public func sync() async {
        guard isEnabled else { return }
        guard !isSyncing else {
            syncAgain = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncAgain = false
            await syncOnce()
        } while syncAgain && isEnabled
    }

    public func hostSaved(_ id: UUID) {
        store.journal.recordSave(id, at: now())
        if isEnabled { Task { await sync() } }
    }

    public func hostDeleted(_ id: UUID) {
        store.journal.recordDeletion(id)
        if isEnabled { Task { await sync() } }
    }

    // MARK: - 內部

    private var isSyncing = false
    private var syncAgain = false

    private func syncOnce() async {
        status = .syncing
        // 到期或退款後停止同步(不送請求)。
        await plus.refresh()
        guard plus.isPlusActive else {
            status = .needsPlus
            return
        }
        var journal = store.journal
        let icons = Dictionary(hosts.hosts.map { ($0.id, hosts.icon(for: $0.id).rawValue) }, uniquingKeysWith: { first, _ in first })
        let changes = journal.pendingChanges(hosts: hosts.hosts, icons: icons, now: now())
        store.journal = journal
        let snapshot: HostSyncSnapshot
        do {
            snapshot = try await session.syncHosts(changes)
        } catch BackendError.signedOut {
            status = .needsPlus
            return
        } catch let BackendError.backend(status, _, _) where status == 403 {
            self.status = .needsPlus
            return
        } catch {
            status = .failed(String(localized: "Couldn’t sync computers. Check your connection and try again."))
            return
        }
        // 同步途中的修改已記在 store 的紀錄裡;以最新的紀錄併回。
        journal = store.journal
        let outcome = journal.reconcile(hosts: hosts.hosts, sent: changes, snapshot: snapshot)
        store.journal = journal
        do {
            try await hosts.applySynced(outcome)
        } catch {
            status = .failed(String(localized: "Couldn’t save synced computers on this device. \(error.localizedDescription)"))
            return
        }
        status = .upToDate(now())
    }
}
