import Foundation

/// 一次性主機指令的期限，依指令性質設定(行為規格「每個指令 20 秒」為預設)。
public enum HostCommandDeadline {
    /// 預設：每個指令 20 秒。
    public static let standard: Duration = .seconds(20)
    /// 探測(主機作業系統):指令很短，卡住要盡早發現。
    public static let probe: Duration = .seconds(10)
    /// 主機要連網下載的指令(`herdr update`、`herdr plugin install`)。
    public static let download: Duration = .seconds(300)

    /// 輸出可能很大的讀取：20 秒加上以 32 KiB/s 估算 `bytes` 的傳輸時間(同圖片上傳)。
    public static func transfer(bytes: Int) -> Duration {
        standard + .milliseconds(bytes / 32)
    }
}

/// 一次性主機指令在期限內沒有結束。通道已經關閉，可以重試。
public enum HostCommandError: Error, Equatable {
    case deadlineExceeded
}
