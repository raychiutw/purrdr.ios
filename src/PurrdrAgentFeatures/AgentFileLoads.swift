import Foundation
import Observation
import PurrdrCore

/// 聊天裡圖片卡片的載入狀態(#225)與點開檔案的下載(#228),每台主機一份(快取跨聊天共用)。畫面在卡片出現時呼叫 `load`,離開畫面時取消。
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

    /// 點開的非圖片檔案(#228):主機路徑 → 狀態。
    public private(set) var opens: [String: OpenState] = [:]
    private let downloader: HostFileDownloader
    private var openTasks: [String: Task<HostFileDownloader.Result, Never>] = [:]

    /// - Parameter downloadDirectory: 點開的檔案下載到這裡(app 傳這台主機在 Caches 底下的資料夾)。
    public init(fetcher: any HostFileFetching, downloadDirectory: URL = AgentFileLoads.defaultDownloadDirectory) {
        loader = HostFileLoader(fetcher: fetcher)
        downloader = HostFileDownloader(fetcher: fetcher, directory: downloadDirectory)
    }

    /// 點開的檔案的狀態(#228)。
    public enum OpenState: Equatable {
        case downloading(received: Int, total: Int)
        /// 已下載到快取，給 QuickLook 與分享。
        case ready(URL)
        /// 超過點擊開啟的上限(25 MiB)。
        case tooLarge(size: Int)
        case missing
        case denied
        case unsupported
        /// 不是一般檔案、讀不到或傳輸失敗;可以再試。
        case failed
    }

    /// 沒指定時的下載資料夾:系統可清除的 Caches 底下。
    public nonisolated static var defaultDownloadDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "HostFiles", directoryHint: .isDirectory)
    }

    /// 點開檔案：下載到快取(版本沒變只查狀態)。回傳可交給 QuickLook 的檔案;取消、超過上限或失敗時 `nil`,原因在 `opens`。
    @discardableResult
    public func open(_ path: String, scope: HostFileAccessScope) async -> URL? {
        openTasks[path]?.cancel()
        opens[path] = .downloading(received: 0, total: 0)
        let downloader = downloader
        let task = Task { [weak self] in
            await downloader.download(path, scope: scope) { received, total in
                Task { @MainActor in self?.reportProgress(path, received: received, total: total) }
            }
        }
        openTasks[path] = task
        let result = await task.value
        // 這次的下載已被新的點擊取代時，不覆寫新的狀態。
        guard openTasks[path] == task else { return nil }
        openTasks[path] = nil
        switch result {
        case .downloaded(let file, _):
            opens[path] = .ready(file)
            return file
        case .tooLarge(let size): opens[path] = .tooLarge(size: size)
        case .missing: opens[path] = .missing
        case .denied: opens[path] = .denied
        case .unsupported: opens[path] = .unsupported
        case .notRegularFile, .unreadable, .failed: opens[path] = .failed
        case .cancelled: opens[path] = nil
        }
        return nil
    }

    /// 取消下載，狀態回到未開啟。
    public func cancelOpen(_ path: String) {
        openTasks[path]?.cancel()
        if case .downloading = opens[path] { opens[path] = nil }
    }

    private func reportProgress(_ path: String, received: Int, total: Int) {
        guard case .downloading = opens[path] else { return }
        opens[path] = .downloading(received: received, total: total)
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
