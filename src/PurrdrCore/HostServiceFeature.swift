import Foundation

/// HTTPS 主機依主機服務版本啟用的功能(#283)。新功能在這裡加一個 case 並在 `minimumVersion` 登記門檻，
/// 再於 `HTTPSHostConnection` 送出前呼叫 `requireHostService(_:)`;版本不足丟 `HostServiceError.hostServiceUpdateRequired`。
public enum HostServiceFeature: String, Sendable, Hashable, CaseIterable {
    /// 主機取檔 `file.stat`／`file.read`(#227)。
    case fileFetch
    /// 新增聊天(`agent.start`)與 workspace／worktree 操作(#287)。
    case workspaceOperations
    /// 上傳圖片與檔案 `file.upload.start`／`file.upload.chunk`(#288)。
    case fileUpload
    /// 列表預覽與 subagent／workflow／委派讀取(`transcript.previews`／`.subagent`／`.workflow`／`.delegation`,#289)。
    case transcriptPreviewsAndDelegations
    /// 從 app 管理主機服務 `host_service.*`(#290)。
    case hostServiceManagement
    /// 列出與撤銷已配對裝置 `devices.list`／`devices.revoke`(#291)。
    case pairedDevices
    /// 主機服務代裝推播外掛 `push.*`。
    case pushPlugin

    /// 有這個功能的第一個主機服務版本。
    public var minimumVersion: HostServiceVersion {
        switch self {
        case .fileFetch: HostServiceVersion(0, 4, 0)
        case .workspaceOperations: HostServiceVersion(0, 7, 0)
        case .fileUpload: HostServiceVersion(0, 7, 0)
        case .transcriptPreviewsAndDelegations: HostServiceVersion(0, 7, 0)
        case .hostServiceManagement: HostServiceVersion(0, 7, 0)
        case .pairedDevices: HostServiceVersion(0, 7, 0)
        case .pushPlugin: HostServiceVersion(0, 6, 0)
        }
    }

    /// 回報 `installedVersion` 的主機服務有沒有這個功能;沒回報或看不懂的版本算沒有。
    public func isAvailable(onHostServiceVersion installedVersion: String?) -> Bool {
        guard let installed = installedVersion.flatMap(HostServiceVersion.init) else { return false }
        return installed >= minimumVersion
    }
}
