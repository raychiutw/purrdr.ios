import Foundation

/// 一次指令執行。stdout／stderr 以串流送出，最後一個事件是 `.exit`。
///
/// 只有主機通道(`PurrdrSSH.HostChannel`)開得出來;放在核心是因為 Pane 終端機連線建在它上面。
public protocol ExecSession: Sendable {
    /// 依到達順序送出 stdout、stderr 與結束狀態;結束狀態之後串流就結束。
    var output: AsyncThrowingStream<ExecOutput, any Error> { get }
    /// 寫進指令的 stdin。
    func write(_ data: Data) async throws
    /// 送出 EOF。注意 `herdr remote-api-bridge` 在 EOF 時會放棄「需要等待」的請求(行為規格 §3.3)。
    func closeStdin() async
    /// 關閉通道(不等指令結束)。
    func close() async
}

/// 指令執行的輸出事件。
public enum ExecOutput: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
    /// 指令結束。被訊號殺死時 `signal` 有值(SSH `exit-signal`)。
    case exit(code: Int32, signal: String? = nil)
}
