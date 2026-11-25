import Foundation
import Synchronization

/// 取檔的記憶體快取(#591):所有主機的 `HostFileLoader` 共用同一個總上限(原始 bytes),
/// 總量以增量維護(不每次加總),記憶體警告時 `removeAll()` 清空。鍵是「載入者 + 路徑 + 版本」,各台主機的同名路徑不互相覆蓋。
public final class HostFileCache: Sendable {
    /// 全 app 共用的預設快取:app 在記憶體警告時清它。
    public static let shared = HostFileCache()

    /// 所有主機合計的預設上限。
    public static let defaultLimit = 48 * 1024 * 1024

    package struct Key: Hashable, Sendable {
        var owner: UUID
        var path: String
        var version: HostFileVersion
    }

    private struct Entry {
        var data: Data
        var tick: UInt64
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var total = 0
        var clock: UInt64 = 0
    }

    private let limit: Int
    private let state = Mutex(State())

    public init(limit: Int = HostFileCache.defaultLimit) {
        self.limit = limit
    }

    /// 目前快取的原始 bytes 總量。
    public var totalBytes: Int { state.withLock { $0.total } }

    /// 記憶體警告時呼叫:全部丟掉,之後需要時重讀。
    public func removeAll() {
        state.withLock {
            $0.entries.removeAll()
            $0.total = 0
        }
    }

    package func value(for key: Key) -> Data? {
        state.withLock { state in
            guard var entry = state.entries[key] else { return nil }
            state.clock += 1
            entry.tick = state.clock
            state.entries[key] = entry
            return entry.data
        }
    }

    package func store(_ data: Data, for key: Key) {
        state.withLock { state in
            // 同一載入者、同一路徑的舊版本不再需要。
            for old in state.entries.keys where old.owner == key.owner && old.path == key.path {
                state.total -= state.entries.removeValue(forKey: old)?.data.count ?? 0
            }
            state.clock += 1
            state.entries[key] = Entry(data: data, tick: state.clock)
            state.total += data.count
            // 超過上限從最久沒用的丟起,至少留下剛存的這筆。
            while state.total > limit, state.entries.count > 1 {
                guard let oldest = state.entries.min(by: { $0.value.tick < $1.value.tick })?.key else { break }
                state.total -= state.entries.removeValue(forKey: oldest)?.data.count ?? 0
            }
        }
    }
}
