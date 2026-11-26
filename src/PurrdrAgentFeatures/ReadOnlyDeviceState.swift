/// 這支裝置是否配對成唯讀(HTTPS)。三種偵測情境(輪詢讀到、回答被拒、送出被拒)都經 `observe(_:)` 切換;
/// 一旦判定為唯讀就維持(之後輪詢讀到可寫入也不解除,維持原本行為)。
public struct ReadOnlyDeviceState: Equatable, Sendable {
    public enum Signal: Equatable, Sendable {
        /// 輪詢時主機回報的唯讀狀態。
        case reported(Bool)
        /// 回答「需要你」時被主機拒絕(`readOnlyDevice`)。
        case answerRejected
        /// 送出 prompt 時被主機拒絕(`SafeSend` 的 `.notSent(.readOnlyDevice)`)。
        case sendRejected
    }

    public private(set) var isReadOnly = false

    public init(isReadOnly: Bool = false) { self.isReadOnly = isReadOnly }

    public mutating func observe(_ signal: Signal) {
        switch signal {
        case .reported(let readOnly): if readOnly { isReadOnly = true }
        case .answerRejected, .sendRejected: isReadOnly = true
        }
    }
}
