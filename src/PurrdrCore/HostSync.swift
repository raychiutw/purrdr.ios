import Foundation

/// 主機同步(GLOSSARY「主機同步」、ADR-0007)的一台主機：只有會在會員各裝置間同步的欄位。
///
/// 刻意是獨立的型別，不直接編碼 `HostConfiguration`:私鑰、密碼、裝置權杖、登入方式、herdr 設定、作業系統都留在這支裝置，
/// 主機設定之後加欄位也不會跟著上傳。
public struct SyncedHost: Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// 位址、埠、使用者名稱。
    public var endpoint: SSHEndpoint
    public var connectionMethod: HostConfiguration.ConnectionMethod
    public var hostKeyPin: HostKeyFingerprint?
    /// HTTPS 主機的主機服務位址(裝置權杖永不同步)。
    public var hostService: HostServiceAddress?
    /// 主機圖示的存檔值(`HostIcon.rawValue`,#243)。`nil` = 沒有圖示資料(舊版 app 上傳的主機)。
    public var icon: String?
    /// 修改這台主機的時間(最後修改者勝)。
    public var modifiedAt: Date

    public init(
        id: UUID, name: String, endpoint: SSHEndpoint, connectionMethod: HostConfiguration.ConnectionMethod,
        hostKeyPin: HostKeyFingerprint?, hostService: HostServiceAddress? = nil, icon: String? = nil, modifiedAt: Date
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.connectionMethod = connectionMethod
        self.hostKeyPin = hostKeyPin
        self.hostService = connectionMethod.usesHostService ? hostService : nil
        self.icon = icon
        self.modifiedAt = modifiedAt
    }

    /// HTTPS 主機的位址欄位是主機服務的主機名稱與埠(後台 wire 必填)。
    public init(_ host: HostConfiguration, modifiedAt: Date, icon: String? = nil) {
        switch host.connection {
        case .tailscaleSSH(let settings), .openSSH(let settings, _):
            self.init(
                id: host.id, name: host.name, endpoint: settings.endpoint, connectionMethod: host.connectionMethod,
                hostKeyPin: settings.hostKeyPin, icon: icon, modifiedAt: modifiedAt)
        case .https(let address):
            self.init(
                id: host.id, name: host.name, endpoint: address.legacyEndpoint,
                connectionMethod: .https, hostKeyPin: nil, hostService: address, icon: icon, modifiedAt: modifiedAt)
        }
    }
}

/// 送給後台的一筆變更。
public enum HostSyncChange: Sendable, Equatable {
    case upsert(SyncedHost)
    case delete(UUID)
}

/// 後台套用變更後，會員目前的主機清單與刪除紀錄。
public struct HostSyncSnapshot: Sendable, Equatable {
    public var hosts: [SyncedHost]
    public var deletedHostIDs: [UUID]

    public init(hosts: [SyncedHost], deletedHostIDs: [UUID]) {
        self.hosts = hosts
        self.deletedHostIDs = deletedHostIDs
    }
}

/// 一次同步後，這支裝置要做的事。
public struct HostSyncOutcome: Sendable, Equatable {
    /// 要存的主機(新的或欄位被別台裝置改過)。
    public var saves: [HostConfiguration]
    /// 別台裝置刪掉、這支裝置也要刪的主機。
    public var deletions: [UUID]
    /// 採用後台版本的主機圖示(存檔值);後台沒有圖示資料的主機不在這裡。
    public var icons: [UUID: String]

    public init(saves: [HostConfiguration] = [], deletions: [UUID] = [], icons: [UUID: String] = [:]) {
        self.saves = saves
        self.deletions = deletions
        self.icons = icons
    }
}

/// 這支裝置的主機修改紀錄：決定哪些變更要上傳，並把後台的結果併回本機。
///
/// - `modified`:這支裝置修改各主機的時間(關閉同步時也記，開啟時才知道誰比較新)。
/// - `synced`:跟後台一致的版本(後台的 `modifiedAt`)。`modified` 與它不同 = 還沒上傳。
/// - `deleted`:還沒上傳的刪除。
///
/// 只有 id 與時間，沒有主機內容、沒有祕密。
public struct HostSyncJournal: Sendable, Equatable, Codable {
    public var modified: [UUID: Date] = [:]
    public var synced: [UUID: Date] = [:]
    public var deleted: Set<UUID> = []

    public init() {}

    /// 這支裝置新增或修改了主機。
    public mutating func recordSave(_ id: UUID, at date: Date) {
        modified[id] = Self.milliseconds(date)
        deleted.remove(id)
    }

    /// 這支裝置刪除了主機。
    public mutating func recordDeletion(_ id: UUID) {
        modified[id] = nil
        synced[id] = nil
        deleted.insert(id)
    }

    /// 要上傳的變更：還沒上傳的修改與刪除。沒有修改紀錄的主機(開啟同步前就存在)以 `now` 當修改時間記下來。
    /// `icons` 是各主機圖示的存檔值。
    public mutating func pendingChanges(hosts: [HostConfiguration], icons: [UUID: String] = [:], now: Date) -> [HostSyncChange] {
        var changes: [HostSyncChange] = []
        for host in hosts.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let modifiedAt = modified[host.id] ?? Self.milliseconds(now)
            modified[host.id] = modifiedAt
            if synced[host.id] != modifiedAt { changes.append(.upsert(SyncedHost(host, modifiedAt: modifiedAt, icon: icons[host.id]))) }
        }
        for id in deleted.sorted(by: { $0.uuidString < $1.uuidString }) {
            changes.append(.delete(id))
        }
        return changes
    }

    /// 把後台的結果併回本機。`sent` 是這次送出的變更;同步途中又被修改或刪除的主機不動(下次再上傳)。
    public mutating func reconcile(hosts: [HostConfiguration], sent: [HostSyncChange], snapshot: HostSyncSnapshot) -> HostSyncOutcome {
        var sentModifiedAt: [UUID: Date] = [:]
        var sentDeletions: Set<UUID> = []
        for change in sent {
            switch change {
            case .upsert(let host): sentModifiedAt[host.id] = host.modifiedAt
            case .delete(let id): sentDeletions.insert(id)
            }
        }
        // 後台已經留下刪除紀錄。
        deleted.subtract(sentDeletions)

        let local = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var outcome = HostSyncOutcome()
        for id in snapshot.deletedHostIDs {
            modified[id] = nil
            synced[id] = nil
            deleted.remove(id)
            if local[id] != nil { outcome.deletions.append(id) }
        }
        for remote in snapshot.hosts {
            // 同步途中刪除的不加回來。
            if deleted.contains(remote.id) { continue }
            // 同步途中又修改的(或這次沒送出、但有還沒上傳的修改)不蓋掉。
            if let mine = modified[remote.id], mine != synced[remote.id], mine != sentModifiedAt[remote.id] { continue }
            // 不完整的同步資料不套用、也不記成已同步，下次同步再處理。
            guard let merged = remote.applied(to: local[remote.id]) else { continue }
            modified[remote.id] = remote.modifiedAt
            synced[remote.id] = remote.modifiedAt
            if merged != local[remote.id] { outcome.saves.append(merged) }
            if let icon = remote.icon { outcome.icons[remote.id] = icon }
        }
        return outcome
    }

    /// 後台的時間只到毫秒;本機也只記到毫秒，後台回來的時間才對得上。
    static func milliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }
}

extension SyncedHost {
    /// 套用到這支裝置的主機設定：只換同步的欄位;沒有這台主機時建立新的(OpenSSH 預設用這支裝置的金鑰)。
    /// HTTPS 主機的裝置權杖不同步，這支裝置要自己連線配對。標成 HTTPS 卻沒有位址時是 `nil`(無法套用)。
    func applied(to existing: HostConfiguration?) -> HostConfiguration? {
        var host = existing ?? HostConfiguration(id: id, name: name, connection: .tailscaleSSH(.init(endpoint: endpoint)))
        host.name = name
        let herdr = host.ssh?.herdr ?? HerdrInstallation()
        let settings = HostConfiguration.SSHSettings(endpoint: endpoint, herdr: herdr, hostKeyPin: hostKeyPin)
        switch connectionMethod {
        case .tailscaleSSH:
            host.connection = .tailscaleSSH(settings)
        case .openSSH:
            host.connection = .openSSH(settings, authentication: host.authentication ?? .deviceKey)
        case .https:
            guard let hostService else { return nil }
            host.connection = .https(hostService)
        }
        return host
    }
}
