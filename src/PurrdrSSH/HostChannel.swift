import Foundation
import PurrdrCore

/// 主機通道:app 對一台主機能做的兩件事——執行指令、開 PTY。
///
/// 實作有三種：真 SSH(swift-nio-ssh,之後的票)、假主機(測試，`PurrdrTestSupport.FakeHost`)、
/// Demo 主機(`PurrdrDemo.DemoHost`)。連線重用、網路切換、逾時、「連線層失敗不重送」都封裝在實作裡，
/// 呼叫端只看到這個介面。
public protocol HostChannel: Sendable {
    /// 在主機上執行一行指令(已依主機作業系統組好、引號化完成的字串)。
    ///
    /// 回傳後指令已經開始執行;stdin 保持開著，直到呼叫端 `closeStdin()` 或 `close()`。
    func execute(_ command: String) async throws -> any ExecSession

    /// 開一個 PTY(`pty-req` + `shell`／`exec`)。`command` 為 `nil` 時開登入 shell。
    func openPTY(_ request: PTYRequest) async throws -> any PTYSession

    /// 關掉底層連線(編輯／刪除主機、信任新 key、連線測試結束時)。下一個指令會重新連線。
    func disconnect() async
}

extension HostChannel {
    public func disconnect() async {}
}

/// 一次指令執行收齊的輸出。
struct CommandResult {
    var stdout = Data()
    var stderr = Data()
    /// 沒有結束狀態(輸出就斷了)時是 -1,見 `didExit`。
    var exitCode: Int32 = -1
    /// 被訊號結束時的訊號名稱(SSH `exit-signal`)。
    var signal: String?
    /// 收到結束狀態。
    var didExit = false
    /// 結束狀態;沒收到是 `nil`。
    var exitStatus: Int32? { didExit ? exitCode : nil }
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    /// Windows 主機的 CLIXML／Rust Debug 格式整理過(`WindowsErrorText`);其他主機只去掉前後空白。
    var stderrText: String { WindowsErrorText.readable(String(decoding: stderr, as: UTF8.self)) }
}

/// 開 PTY 的參數。
public struct PTYRequest: Sendable, Equatable {
    /// 要執行的指令;`nil` 是登入 shell。
    public var command: String?
    public var columns: Int
    public var rows: Int
    public var term: String

    public init(command: String? = nil, columns: Int, rows: Int, term: String = "xterm-256color") {
        self.command = command
        self.columns = columns
        self.rows = rows
        self.term = term
    }
}

/// 一個 PTY 連線。輸出是原始 bytes(含 ANSI)。
public protocol PTYSession: Sendable {
    var output: AsyncThrowingStream<Data, any Error> { get }
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func close() async
}
