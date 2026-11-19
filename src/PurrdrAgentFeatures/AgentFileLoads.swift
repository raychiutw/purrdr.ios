import Foundation
import Observation
import PurrdrCore

/// 聊天裡圖片卡片的載入狀態(#225),每台主機一份(快取跨聊天共用)。畫面在卡片出現時呼叫 `load`,離開畫面時取消。
@MainActor
@Observable
public final class AgentFileLoads {
    public enum State: Equatable {
        case loading
        case loaded(Data, version: HostFileVersion)
        /// 超過自動載入上限，等使用者點擊。
        case overAutomaticLimit(size: Int)
        /// 超過取檔上限，不能載入。
        case tooLarge(size: Int)
        case missing
        /// 存取規則不允許(工作目錄之外且對話紀錄沒出現過、排除清單、symlink 跳出)。
        case denied
        /// 這台主機還不能取檔(Windows、HTTPS 主機)。
        case unsupported
        /// 不是一般檔案、讀不到或傳輸失敗;可以再試。
        case failed
    }

    /// 主機路徑 → 狀態。
    public private(set) var states: [String: State] = [:]
    private let loader: HostFileLoader

    public init(fetcher: any HostFileFetching) {
        loader = HostFileLoader(fetcher: fetcher)
    }

    /// 載入一張圖。已載入的照樣先查狀態(版本沒變用快取、不傳內容)。
    /// - Parameter userRequested: 使用者點了「載入」:上限放寬到 25 MiB。
    public func load(_ path: String, scope: HostFileAccessScope, userRequested: Bool = false) async {
        // 已顯示縮圖時不換回載入中，版本變了才換圖。
        let isShowing = if case .loaded = states[path] { true } else { false }
        if !isShowing || userRequested { states[path] = .loading }
        let result = await loader.load(path, scope: scope, userRequested: userRequested)
        switch result {
        case .loaded(let data, let version): states[path] = .loaded(data, version: version)
        case .overAutomaticLimit(let size): states[path] = .overAutomaticLimit(size: size)
        case .tooLarge(let size): states[path] = .tooLarge(size: size)
        case .missing: states[path] = .missing
        case .denied: states[path] = .denied
        case .unsupported: states[path] = .unsupported
        case .notRegularFile, .unreadable, .failed: states[path] = .failed
        case .cancelled: if states[path] == .loading { states[path] = nil }
        }
    }
}
