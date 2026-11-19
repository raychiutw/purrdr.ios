import Foundation

/// 經主機取檔讀整個檔案(#225,圖片縮圖用):先過 app 端存取規則，查狀態，依大小上限決定讀不讀，依版本分塊讀完。
/// 讀過的 bytes 依「路徑 + 版本」放記憶體快取，版本沒變只查狀態;Agent 覆寫同名檔(版本變了)就重讀。
public actor HostFileLoader {
    public enum Result: Sendable, Equatable {
        case loaded(Data, version: HostFileVersion)
        /// 超過自動載入上限(`HostFileFetchLimits.automaticLoad`),等使用者點擊。
        case overAutomaticLimit(size: Int)
        /// 超過取檔上限，不能載入。
        case tooLarge(size: Int)
        case missing
        case notRegularFile
        case unreadable
        /// app 端或主機端的存取規則不允許。
        case denied
        /// 這個連線方式或主機還不能取檔。
        case unsupported
        case cancelled
        case failed(String)
    }

    private struct CacheKey: Hashable {
        var path: String
        var version: HostFileVersion
    }

    private let fetcher: any HostFileFetching
    private let cacheLimit: Int
    private var cache: [CacheKey: Data] = [:]
    /// 最近用過的在後面;超過上限從前面丟。
    private var recentlyUsed: [CacheKey] = []

    /// - Parameter cacheLimit: 記憶體快取的總 bytes。
    public init(fetcher: any HostFileFetching, cacheLimit: Int = 48 * 1024 * 1024) {
        self.fetcher = fetcher
        self.cacheLimit = cacheLimit
    }

    /// - Parameter userRequested: 使用者點了「載入」:上限放寬到 `HostFileFetchLimits.maximumSize`。
    public func load(_ path: String, scope: HostFileAccessScope, userRequested: Bool = false) async -> Result {
        guard case .allowed(let target) = HostFileAccessPolicy.decision(for: path, in: scope) else { return .denied }
        // 分塊之間被覆寫(changed)時重新查狀態再讀一次。
        for _ in 0..<2 {
            do {
                let status = try await fetcher.status(of: target)
                guard case .file(let version, let size) = status else { return Self.result(of: status) }
                let key = CacheKey(path: path, version: version)
                if let cached = cache[key] {
                    touch(key)
                    return .loaded(cached, version: version)
                }
                let limit = userRequested ? HostFileFetchLimits.maximumSize : HostFileFetchLimits.automaticLoad
                guard size <= limit else { return userRequested ? .tooLarge(size: size) : .overAutomaticLimit(size: size) }
                var data = Data(capacity: size)
                while data.count < size {
                    try Task.checkCancellation()
                    let chunk = try await fetcher.read(
                        target, version: version, offset: data.count, length: min(HostFileFetchLimits.chunkSize, size - data.count))
                    guard !chunk.isEmpty else { return .failed("host file ended early") }
                    data.append(chunk)
                }
                store(data, for: key)
                return .loaded(data, version: version)
            } catch HostFileFetchError.changed {
                continue
            } catch HostFileFetchError.unavailable(let status) {
                return Self.result(of: status)
            } catch HostFileFetchError.unsupported {
                return .unsupported
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(String(describing: error))
            }
        }
        return .failed("host file kept changing")
    }

    private static func result(of status: HostFileStatus) -> Result {
        switch status {
        case .file: .failed("unexpected file status")
        case .missing: .missing
        case .notRegularFile: .notRegularFile
        case .unreadable: .unreadable
        case .denied: .denied
        case .tooLarge(let size): .tooLarge(size: size)
        }
    }

    private func touch(_ key: CacheKey) {
        recentlyUsed.removeAll { $0 == key }
        recentlyUsed.append(key)
    }

    private func store(_ data: Data, for key: CacheKey) {
        // 同一路徑的舊版本不再需要。
        for old in recentlyUsed where old.path == key.path { cache[old] = nil }
        recentlyUsed.removeAll { $0.path == key.path }
        cache[key] = data
        recentlyUsed.append(key)
        var total = cache.values.reduce(0) { $0 + $1.count }
        while total > cacheLimit, recentlyUsed.count > 1 {
            let evicted = recentlyUsed.removeFirst()
            total -= cache.removeValue(forKey: evicted)?.count ?? 0
        }
    }
}
