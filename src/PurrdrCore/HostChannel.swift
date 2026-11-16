import Foundation

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

    /// 執行一般指令(先送 EOF),收齊輸出。非零 exit 是結果不是例外(行為規格 §3.2)。
    func collect(_ command: String) async throws -> CommandResult {
        let session = try await execute(command)
        await session.closeStdin()
        var result = CommandResult()
        for try await event in session.output {
            switch event {
            case .stdout(let data): result.stdout.append(data)
            case .stderr(let data): result.stderr.append(data)
            case .exit(let code, _): result.exitCode = code
            }
        }
        return result
    }
}

/// 一次指令執行收齊的輸出。
struct CommandResult {
    var stdout = Data()
    var stderr = Data()
    var exitCode: Int32 = -1
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    /// Windows 主機的 CLIXML／Rust Debug 格式整理過(`WindowsErrorText`);其他主機只去掉前後空白。
    var stderrText: String { WindowsErrorText.readable(String(decoding: stderr, as: UTF8.self)) }
}

/// 一次指令執行。stdout／stderr 以串流送出，最後一個事件是 `.exit`。
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
