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

    private let fetcher: any HostFileFetching
    private let cache: HostFileCache
    /// 這個載入者在共用快取裡的命名空間(各台主機的同名路徑不互相覆蓋)。
    private let owner = UUID()

    /// - Parameter cache: 記憶體快取;預設是全 app 共用的 `HostFileCache.shared`(總上限由它管)。
    public init(fetcher: any HostFileFetching, cache: HostFileCache = .shared) {
        self.fetcher = fetcher
        self.cache = cache
    }

    /// - Parameters:
    ///   - userRequested: 使用者點了「載入」:上限放寬到 `HostFileFetchLimits.maximumSize`,也不限圖片格式。
    ///   - automaticImageFormatsOnly: 內容要以 ImageIO 解碼時為 `true`:不是 PNG／JPEG／HEIC／GIF／WebP 的檔案不自動載入(#579)。
    public func load(
        _ path: String, scope: HostFileAccessScope, userRequested: Bool = false, automaticImageFormatsOnly: Bool = false
    ) async -> Outcome {
        let attempt = await HostFileFetchAttempt.run(path, scope: scope, fetcher: fetcher) { target, version, size -> Outcome in
            let key = HostFileCache.Key(owner: owner, path: path, version: version)
            if let cached = cache.value(for: key) {
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
                // 第一塊就判斷格式:不是常見格式不再往下讀，等使用者點擊。
                if automaticImageFormatsOnly, !userRequested, data.count == chunk.count, AutoDecodableImageFormat.detect(chunk) == nil {
                    return .overAutomaticLimit(size: size)
                }
            }
            cache.store(data, for: key)
            return .loaded(data, version: version)
        }
        switch attempt {
        case .success(let outcome): return outcome
        case .failure(let problem): return .unavailable(problem)
        }
    }

    /// 只查狀態(不讀內容):檔案卡片顯示大小或原因(#429)。成功回大小。
    public func size(of path: String, scope: HostFileAccessScope) async -> Result<Int, HostFileProblem> {
        await HostFileFetchAttempt.run(path, scope: scope, fetcher: fetcher) { _, _, size in size }
    }
}
