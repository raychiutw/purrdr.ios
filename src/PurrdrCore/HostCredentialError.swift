import Foundation

public enum HostCredentialError: Error, Equatable {
    /// 主機設定在，但這台主機的密碼或私鑰不在這支裝置上(例如從備份還原)。不要用空密碼去試(行為規格 §8.1)。
    case missingSecret
}
