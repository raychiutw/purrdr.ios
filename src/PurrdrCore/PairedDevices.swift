import Foundation

/// 一支和這台主機完成連線配對的裝置(#291;不是推播配對的通知裝置)。
public struct PairedDeviceRecord: Sendable, Equatable, Identifiable {
    /// 主機服務給的裝置識別碼。
    public let id: String
    /// 配對時 app 給的裝置名稱。
    public let name: String
    /// 配對成唯讀。
    public let isReadOnly: Bool
    public let pairedAt: Date
    /// 是發出請求的這支裝置。
    public let isCurrentDevice: Bool

    public init(id: String, name: String, isReadOnly: Bool, pairedAt: Date, isCurrentDevice: Bool) {
        self.id = id
        self.name = name
        self.isReadOnly = isReadOnly
        self.pairedAt = pairedAt
        self.isCurrentDevice = isCurrentDevice
    }
}

/// 列出與撤銷主機上已配對的裝置(主機服務 `devices.list`／`devices.revoke`)。
public protocol PairedDevicesManaging: Sendable {
    /// 依配對先後;不含已撤銷的。
    func pairedDevices() async throws -> [PairedDeviceRecord]
    /// 撤銷別支裝置(主機拒絕撤銷自己);已撤銷的再撤銷也成功，不認得的丟 `HostServiceError.deviceUnknown`。
    func revokePairedDevice(_ id: String) async throws
    /// 這支裝置配對成唯讀(不能撤銷)。
    func isReadOnlyDevice() async throws -> Bool
}
