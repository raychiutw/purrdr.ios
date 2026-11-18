/// WSS 心跳：每 `interval` 送一次 WebSocket ping,`timeout` 內沒收到 pong 就斷線(之後的操作重新撥號)。
public struct HostServiceHeartbeat: Sendable, Equatable {
    public var interval: Duration
    public var timeout: Duration

    public init(interval: Duration, timeout: Duration) {
        self.interval = interval
        self.timeout = timeout
    }

    /// 主機服務 45 秒沒收到任何東西就斷線，所以 app 每 15 秒 ping 一次。
    public static let standard = HostServiceHeartbeat(interval: .seconds(15), timeout: .seconds(10))
}
