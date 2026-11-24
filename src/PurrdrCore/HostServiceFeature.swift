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
    /// Agent 觀察者：「可能卡住」「仍在等你」推播、Send When Done(raychiutw/purrdr.host#25)。
    case agentObserver
    /// 讀 Pane 畫面 `pane.read`(#303):提問卡、計畫卡、建議提示詞、slash 面板與即時預覽。
    case paneRead
    /// 列出資料夾過去的 session 與以 `resume_session` 續接(`sessions.list`／`agent.start`,#309)。
    case sessionResume
    /// 送出前比對 `expected_session`,不符回 `pane_changed`(#304、raychiutw/purrdr.host#29)。
    case sendExpectations
    /// 變更頁的唯讀 git 讀取 `git.status`／`git.diff`(#310)。
    case gitChanges
    /// 測試通知 `push.test`(raychiutw/purrdr.host#60)。
    case pushTest
    /// 對話紀錄視窗的位元組上限 `transcript.window` 的 `max_bytes`(#356、raychiutw/purrdr.host#52)。
    case transcriptWindowMaxBytes
    /// 方案用量 `usage.codex`／`usage.claude`(raychiutw/purrdr.host#62)。
    case planUsage
    /// 每個 Claude session 的 context 用量 `usage.session_context`(raychiutw/purrdr.host#62、#64)。
    case sessionContext
    /// 用量擷取(Claude status line 包裝)的狀態、安裝與還原 `claude_usage.status`／`install`／`remove`;後兩者是寫入類。
    case claudeUsageSetup
    /// 資料夾瀏覽 `directory.list` 與 `welcome.home_directory`(raychiutw/purrdr.host#26)。
    case directoryBrowsing
    /// 主機服務直接送推播:`push.*` 結果的 `direct_push`(有的話 `push.install` 不安裝外掛)。
    case directPush
    /// 取檔放行使用者 prompt 裡 Purrdr 上傳資料夾的路徑(raychiutw/purrdr.host#73、#430);更舊的主機服務一律回 `denied`。
    case userUploadFetch
    /// 重新命名 Tab `tab.rename`(#458、raychiutw/purrdr.host#78)。
    case tabRename
    /// 在既有 Workspace 新增 Tab `tab.create`(raychiutw/purrdr.host#90,0.15.0)。
    case tabCreate
    /// 關閉 Tab `tab.close`(raychiutw/purrdr.host#91,0.15.0;最後一個 Tab 會連 Workspace 一起關,仍回成功)。
    case tabClose
    /// `agent.start.result` 的 `launch_pending`(raychiutw/purrdr.host#92,0.15.0):主機服務等過 agent 就緒才回。
    /// 更舊的主機服務不帶這個欄位,app 一律當就緒;不擋送出,只供畫面判斷。
    case agentStartLaunchState

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
        case .agentObserver: HostServiceVersion(0, 7, 0)
        case .paneRead: HostServiceVersion(0, 7, 0)
        case .sessionResume: HostServiceVersion(0, 7, 0)
        case .sendExpectations: HostServiceVersion(0, 7, 0)
        case .gitChanges: HostServiceVersion(0, 7, 0)
        case .pushTest: HostServiceVersion(0, 11, 0)
        case .transcriptWindowMaxBytes: HostServiceVersion(0, 11, 0)
        case .planUsage: HostServiceVersion(0, 12, 0)
        case .sessionContext: HostServiceVersion(0, 12, 0)
        case .claudeUsageSetup: HostServiceVersion(0, 12, 0)
        case .directoryBrowsing: HostServiceVersion(0, 12, 0)
        case .directPush: HostServiceVersion(0, 12, 0)
        case .userUploadFetch: HostServiceVersion(0, 13, 0)
        case .tabRename: HostServiceVersion(0, 13, 1)
        case .tabCreate: HostServiceVersion(0, 15, 0)
        case .tabClose: HostServiceVersion(0, 15, 0)
        case .agentStartLaunchState: HostServiceVersion(0, 15, 0)
        }
    }

    /// 回報 `installedVersion` 的主機服務有沒有這個功能;沒回報或看不懂的版本算沒有。
    public func isAvailable(onHostServiceVersion installedVersion: String?) -> Bool {
        guard let installed = installedVersion.flatMap(HostServiceVersion.init) else { return false }
        return installed >= minimumVersion
    }
}
