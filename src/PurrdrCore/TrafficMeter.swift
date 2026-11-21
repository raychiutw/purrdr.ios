import Foundation
import Synchronization

/// 流量的網路類型。由平台注入(iOS 以網路路徑監看)，核心只收「目前是哪一種」。
public enum TrafficNetwork: String, Sendable, Codable, CaseIterable, Hashable {
    case wifi
    case cellular
    case other
}

extension TrafficNetwork {
    /// 路徑實際走的介面換成計量的類型:Wi-Fi 優先(同時有 Wi-Fi 與行動網路時流量走 Wi-Fi),其次行動網路,其餘(有線、VPN 等)是其他。
    public init(usesWiFi: Bool, usesCellular: Bool) {
        self = usesWiFi ? .wifi : usesCellular ? .cellular : .other
    }
}

public enum TrafficDirection: Sendable, Hashable {
    case sent
    case received
}

/// 一組送出與收到的位元組。
public struct TrafficBytes: Sendable, Codable, Equatable {
    public var sent: Int
    public var received: Int

    public init(sent: Int = 0, received: Int = 0) {
        self.sent = sent
        self.received = received
    }

    public var total: Int { sent + received }

    public static func + (lhs: TrafficBytes, rhs: TrafficBytes) -> TrafficBytes {
        TrafficBytes(sent: lhs.sent + rhs.sent, received: lhs.received + rhs.received)
    }
}

/// 一台主機在各網路類型的用量。
public typealias HostTraffic = [TrafficNetwork: TrafficBytes]

/// 一天(本地時區)的用量:主機 id → 網路類型 → 位元組。
public struct TrafficDay: Sendable, Codable, Equatable {
    /// `yyyy-MM-dd`(本地時區的日曆日)。
    public var day: String
    public var hosts: [String: HostTraffic]

    public init(day: String, hosts: [String: HostTraffic] = [:]) {
        self.day = day
        self.hosts = hosts
    }
}

/// 主機連線層回報位元組的入口(連線不知道計量長什麼樣子)。
public typealias TrafficRecording = @Sendable (TrafficDirection, Int) -> Void

/// 用量的存放處。每天一筆，只存這支裝置(不同步、不上傳)。
public protocol TrafficStore: Sendable {
    func load() -> [TrafficDay]
    func save(_ days: [TrafficDay])
}

/// 只在記憶體(UI 測試、單元測試)。
public final class InMemoryTrafficStore: TrafficStore {
    private let state = Mutex<(days: [TrafficDay], saves: Int)>(([], 0))

    public init(days: [TrafficDay] = []) { state.withLock { $0.days = days } }

    public func load() -> [TrafficDay] { state.withLock { $0.days } }

    public func save(_ days: [TrafficDay]) {
        state.withLock {
            $0.days = days
            $0.saves += 1
        }
    }

    /// 寫入次數(測試用)。
    public var saveCount: Int { state.withLock { $0.saves } }
}

/// 存成一個 JSON 檔。讀不懂(壞檔)當作沒有資料;寫失敗不影響 app(下次再寫)。
public struct FileTrafficStore: TrafficStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [TrafficDay] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TrafficDay].self, from: data)) ?? []
    }

    public func save(_ days: [TrafficDay]) {
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        #if canImport(Darwin)
        // 只屬於這支裝置的用量:不進 iCloud 備份(#353)。原子寫入每次換新檔，所以每次都要標。
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try? excluded.setResourceValues(values)
        #endif
    }
}

/// 主機連線建好之後才接上計量的轉接點:沒接時不記。SSH 主機通道與 HTTPS 主機連線各持有一個。
public final class TrafficSink: Sendable {
    private let recording: Mutex<TrafficRecording?>

    public init(_ recording: TrafficRecording? = nil) { self.recording = Mutex(recording) }

    public func attach(_ recording: TrafficRecording?) { self.recording.withLock { $0 = recording } }

    public func record(_ direction: TrafficDirection, _ bytes: Int) {
        let current = recording.withLock { $0 }
        current?(direction, bytes)
    }
}

/// 流量計量(#353,spec #337):依主機 × 網路類型 × 方向累計，按日存 30 天;「這次開啟」只在記憶體。
///
/// 時鐘與日曆注入(分日用本地時區的午夜)。寫入存放處有節流,`flush()` 一定寫(app 進背景時呼叫)。
public final class TrafficMeter: Sendable {
    /// 保留的天數(含今天)。
    public static let retentionDays = 30
    /// 兩次自動寫入的最短間隔。
    public static let saveInterval: TimeInterval = 5

    private struct State {
        var days: [String: [String: HostTraffic]]
        var launch: [String: HostTraffic] = [:]
        var network: TrafficNetwork
        var lastSave: Date?
        var dirty = false
    }

    private let state: Mutex<State>
    private let store: any TrafficStore
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        store: any TrafficStore, now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current,
        network: TrafficNetwork = .other
    ) {
        self.store = store
        self.now = now
        self.calendar = calendar
        var loaded: [String: [String: HostTraffic]] = [:]
        for day in store.load() { loaded[day.day] = day.hosts }
        state = Mutex(State(days: loaded, network: network))
    }

    /// 平台回報目前的網路類型;之後的位元組記在這一類。
    public func setNetwork(_ network: TrafficNetwork) {
        state.withLock { $0.network = network }
    }

    /// 某台主機的計量入口,交給它的連線。
    public func recorder(for hostID: String) -> TrafficRecording {
        { [self] direction, bytes in record(hostID: hostID, direction: direction, bytes: bytes) }
    }

    public func record(hostID: String, direction: TrafficDirection, bytes: Int) {
        guard bytes > 0 else { return }
        let date = now()
        let today = dayKey(date)
        let toSave: [TrafficDay]? = state.withLock { state in
            prune(&state, today: date)
            let network = state.network
            func add(_ traffic: inout [String: HostTraffic]) {
                var entry = traffic[hostID, default: [:]][network, default: TrafficBytes()]
                switch direction {
                case .sent: entry.sent += bytes
                case .received: entry.received += bytes
                }
                traffic[hostID, default: [:]][network] = entry
            }
            add(&state.launch)
            add(&state.days[today, default: [:]])
            state.dirty = true
            if let last = state.lastSave, date.timeIntervalSince(last) < Self.saveInterval { return nil }
            state.lastSave = date
            state.dirty = false
            return Self.snapshot(state)
        }
        if let toSave { store.save(toSave) }
    }

    /// 保留中的每一天(舊到新)。
    public func days() -> [TrafficDay] {
        state.withLock { state in
            prune(&state, today: now())
            return Self.snapshot(state)
        }
    }

    /// 今天(本地時區)各主機的用量。
    public func today() -> [String: HostTraffic] {
        let key = dayKey(now())
        return state.withLock { state in
            prune(&state, today: now())
            return state.days[key] ?? [:]
        }
    }

    /// 這次開啟(從 app 啟動算起,只在記憶體)各主機的用量。
    public func sinceLaunch() -> [String: HostTraffic] {
        state.withLock { $0.launch }
    }

    /// 把還沒寫的用量寫進存放處。
    public func flush() {
        let toSave: [TrafficDay]? = state.withLock { state in
            prune(&state, today: now())
            guard state.dirty else { return nil }
            state.dirty = false
            state.lastSave = now()
            return Self.snapshot(state)
        }
        if let toSave { store.save(toSave) }
    }

    /// 重設統計:清掉所有歷史與這次開啟。
    public func reset() {
        state.withLock { state in
            state.days = [:]
            state.launch = [:]
            state.dirty = false
            state.lastSave = now()
        }
        store.save([])
    }

    // MARK: - 內部

    private static func snapshot(_ state: State) -> [TrafficDay] {
        state.days.keys.sorted().map { TrafficDay(day: $0, hosts: state.days[$0] ?? [:]) }
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 丟掉保留範圍(今天往前 30 天,含今天)之前的天。
    private func prune(_ state: inout State, today: Date) {
        let start = calendar.startOfDay(for: today)
        guard let oldest = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: start) else { return }
        let cutoff = dayKey(oldest)
        let expired = state.days.keys.filter { $0 < cutoff }
        guard !expired.isEmpty else { return }
        for key in expired { state.days[key] = nil }
        state.dirty = true
    }
}
