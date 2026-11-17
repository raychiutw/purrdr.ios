import Foundation

public enum DeviceKeyError: Error, Equatable {
    /// 這台裝置(例如模擬器)沒有 Secure Enclave。
    case secureEnclaveUnavailable
}
