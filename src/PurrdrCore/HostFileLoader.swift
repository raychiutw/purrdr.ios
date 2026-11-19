import Foundation

/// 經主機取檔讀整個檔案(#225,圖片縮圖用):先過 app 端存取規則，查狀態，依大小上限決定讀不讀，依版本分塊讀完。
/// 讀過的 bytes 依「路徑 + 版本」放記憶體快取，版本沒變只查狀態;Agent 覆寫同名檔(版本變了)就重讀。
public actor HostFileLoader {
    public enum Outcome: Sendable, Equatable {
        case loaded(Data, version: HostFileVersion)
        /// 超過自動載入上限(`HostFileFetchLimits.automaticLoad`),等使用者點擊。
        case overAutomaticLimit(size: Int)
        case unavailable(HostFileProblem)
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
    public func load(_ path: String, scope: HostFileAccessScope, userRequested: Bool = false) async -> Outcome {
        let attempt = await HostFileFetchAttempt.run(path, scope: scope, fetcher: fetcher) { target, version, size -> Outcome in
            let key = CacheKey(path: path, version: version)
            if let cached = cache[key] {
                touch(key)
                return .loaded(cached, version: version)
            }
            if !userRequested, size > HostFileFetchLimits.automaticLoad { return .overAutomaticLimit(size: size) }
            if size > HostFileFetchLimits.maximumSize { throw HostFileProblem.tooLarge(size: size) }
            var data = Data(capacity: size)
            while data.count < size {
                try Task.checkCancellation()
                let chunk = try await fetcher.read(
                    target, version: version, offset: data.count, length: min(HostFileFetchLimits.chunkSize, size - data.count))
                guard !chunk.isEmpty else { throw HostFileProblem.failed("host file ended early") }
                data.append(chunk)
            }
            store(data, for: key)
            return .loaded(data, version: version)
        }
        switch attempt {
        case .success(let outcome): return outcome
        case .failure(let problem): return .unavailable(problem)
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
