import Foundation
import PurrdrCore

/// 假主機(Seam 1):對「預期的指令」回放錄製的真實回應，並記錄 app 實際送出的指令與 stdin。
///
/// ```swift
/// let host = FakeHost()
/// await host.expect(HerdrCommand.bridge(), reply: .recorded("session.snapshot.ndjson"))
/// // …讓 app 透過 host 做事…
/// #expect(await host.executions.map(\.command) == [HerdrCommand.bridge()])
/// ```
///
/// 沒有預期的指令一律以 `FakeHostError.unexpectedCommand` 失敗，不會默默回空結果。
public actor FakeHost: HostChannel {
    /// app 對主機執行過的一次指令。
    public struct Execution: Sendable, Equatable {
        public var command: String
        /// 到目前為止寫進 stdin 的全部 bytes。
        public var stdin: Data
        /// app 是否送出 EOF。
        public var closedStdin: Bool
        /// app 是否關閉了通道。
        public var closed: Bool

        /// stdin 當成 UTF-8 文字。
        public var stdinText: String { String(decoding: stdin, as: UTF8.self) }
    }

    /// app 對主機開過的一次 PTY。
    public struct PTYOpening: Sendable, Equatable {
        public var request: PTYRequest
        public var input: Data
        public var sizes: [Size]
        public var closed: Bool

        public init(request: PTYRequest, input: Data, sizes: [Size], closed: Bool) {
            self.request = request
            self.input = input
            self.sizes = sizes
            self.closed = closed
        }

        public struct Size: Sendable, Equatable {
            public var columns: Int
            public var rows: Int

            public init(columns: Int, rows: Int) {
                self.columns = columns
                self.rows = rows
            }
        }
    }

    public private(set) var executions: [Execution] = []
    public private(set) var ptys: [PTYOpening] = []

    private var expectations: [(command: String, reply: FakeReply)] = []
    private var connectionError: (any Error)?
    private var ptyExpectations: [(request: PTYRequest, output: Data)] = []
    private var ptyOutputs: [Int: AsyncThrowingStream<Data, any Error>.Continuation] = [:]
    private var pending: [Int: (reply: FakeReply, continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation)] = [:]
    /// 回應完仍保持開著的串流(`FakeReply.keepsOpen`),測試可以再 `send`／`finish`。
    private var open: [Int: AsyncThrowingStream<ExecOutput, any Error>.Continuation] = [:]

    public init() {}

    /// 預期 app 會執行 `command`(完全相同的字串),並以 `reply` 回應。同一指令可預期多次，依序消耗。
    public func expect(_ command: String, reply: FakeReply) {
        expectations.append((command, reply))
    }

    /// 預期 app 會以 `request` 開 PTY,開啟後送出 `output`。
    public func expectPTY(_ request: PTYRequest, output: Data = Data()) {
        ptyExpectations.append((request, output))
    }

    /// 還沒被執行到的預期指令。測試結尾可斷言它是空的。
    public var unmetExpectations: [String] { expectations.map(\.command) }

    /// 之後的每個指令都以 `error` 失敗(模擬連線層錯誤，例如 host key 待確認、連不上)。
    public func failConnection(with error: any Error) {
        connectionError = error
    }

    /// 連線恢復：之後的指令照預期回應。
    public func restoreConnection() {
        connectionError = nil
    }

    /// 測試結束或主機設定改變時 app 關掉了連線。
    public private(set) var disconnectCount = 0

    public func disconnect() async {
        disconnectCount += 1
    }

    public func execute(_ command: String) async throws -> any ExecSession {
        if let connectionError { throw connectionError }
        guard let index = expectations.firstIndex(where: { $0.command == command }) else {
            throw FakeHostError.unexpectedCommand(command)
        }
        let reply = expectations.remove(at: index).reply
        let id = executions.count
        executions.append(Execution(command: command, stdin: Data(), closedStdin: false, closed: false))
        let (stream, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
        if reply.trigger == .immediately {
            emit(reply, to: continuation, for: id)
        } else {
            pending[id] = (reply, continuation)
        }
        return FakeExecSession(host: self, id: id, output: stream)
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        guard let index = ptyExpectations.firstIndex(where: { $0.request == request }) else {
            throw FakeHostError.unexpectedPTY(request)
        }
        let output = ptyExpectations.remove(at: index).output
        let id = ptys.count
        ptys.append(PTYOpening(request: request, input: Data(), sizes: [], closed: false))
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        if !output.isEmpty { continuation.yield(output) }
        ptyOutputs[id] = continuation
        return FakePTYSession(host: self, id: id, output: stream, continuation: continuation)
    }

    /// 對第 `index` 個 PTY 送出畫面輸出。
    public func send(_ output: Data, toPTY index: Int) {
        ptyOutputs[index]?.yield(output)
    }

    /// 結束第 `index` 個 PTY:`error` 為 `nil` 時是程式自己結束，否則是連線中斷。
    public func endPTY(_ index: Int, throwing error: (any Error)? = nil) {
        if let error {
            ptyOutputs[index]?.finish(throwing: error)
        } else {
            ptyOutputs[index]?.finish()
        }
    }

    /// 等到 app 開了 `count` 個 PTY。逾時則回傳目前數量。
    public func waitForPTYs(_ count: Int, timeout: Duration = asyncWaitLimit) async -> Int {
        let deadline = ContinuousClock.now + timeout
        while ptys.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return ptys.count
    }

    /// 對第 `index` 次執行(`keepsOpen` 的串流)送出任一種輸出事件(stdout 或 stderr)。
    public func send(_ output: ExecOutput, toExecution index: Int) {
        open[index]?.yield(output)
    }

    /// 等到 app 執行了 `count` 個指令(測試與 app 的非同步工作對齊用)。逾時則回傳目前數量。
    public func waitForExecutions(_ count: Int, timeout: Duration = asyncWaitLimit) async -> Int {
        let deadline = ContinuousClock.now + timeout
        while executions.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return executions.count
    }

    /// 等到第 `index` 個執行的 stdin 滿足 `condition`。逾時則回傳 `false`。
    public func waitForStdin(
        ofExecution index: Int, timeout: Duration = asyncWaitLimit, until condition: @Sendable (Execution) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if index < executions.count, condition(executions[index]) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// 等到 app 關閉第 `index` 個執行的通道。逾時則回傳 `false`。
    public func waitUntilClosed(execution index: Int, timeout: Duration = asyncWaitLimit) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if index < executions.count, executions[index].closed { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    // MARK: - 給 session 回報

    fileprivate func received(_ data: Data, for id: Int) throws {
        guard !executions[id].closedStdin, !executions[id].closed else { throw FakeHostError.writeAfterClose }
        executions[id].stdin.append(data)
        if let waiting = pending[id], waiting.reply.trigger == .afterStdinLine, executions[id].stdin.contains(0x0A) {
            pending[id] = nil
            emit(waiting.reply, to: waiting.continuation, for: id)
        }
    }

    fileprivate func closedStdin(for id: Int) {
        executions[id].closedStdin = true
        // 真的 bridge 在 stdin 一行都沒收到就 EOF 時，什麼都不回、exit 0(行為規格 §3.3)。
        if let waiting = pending.removeValue(forKey: id) {
            waiting.continuation.yield(.exit(code: 0))
            waiting.continuation.finish()
        }
    }

    fileprivate func closed(_ id: Int) {
        executions[id].closed = true
        pending.removeValue(forKey: id)?.continuation.finish()
        open.removeValue(forKey: id)?.finish()
    }

    fileprivate func ptyReceived(_ data: Data, for id: Int) { ptys[id].input.append(data) }
    fileprivate func ptyResized(_ id: Int, columns: Int, rows: Int) { ptys[id].sizes.append(.init(columns: columns, rows: rows)) }
    fileprivate func ptyClosed(_ id: Int) { ptys[id].closed = true }

    private func emit(_ reply: FakeReply, to continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation, for id: Int) {
        if !reply.stdout.isEmpty { continuation.yield(.stdout(reply.stdout)) }
        if !reply.stderr.isEmpty { continuation.yield(.stderr(reply.stderr)) }
        if reply.keepsOpen {
            open[id] = continuation
            return
        }
        continuation.yield(.exit(code: reply.exitCode))
        continuation.finish()
    }

    // MARK: - 給測試推送(`keepsOpen` 的串流)

    /// 對第 `execution` 次執行(從 0 起算)再送出 stdout,例如訂閱中的一行事件。
    public func send(stdout: Data, toExecution execution: Int) {
        open[execution]?.yield(.stdout(stdout))
    }

    /// 結束第 `execution` 次執行(例如主機那端的串流斷了)。
    public func finish(execution: Int, exitCode: Int32 = 0) {
        open.removeValue(forKey: execution).map {
            $0.yield(.exit(code: exitCode))
            $0.finish()
        }
    }
}

/// 假主機對一個指令的回應。
public struct FakeReply: Sendable {
    public enum Trigger: Sendable {
        /// 指令一開始就回應(一般指令)。
        case immediately
        /// 等 stdin 收到第一個換行才回應(`herdr remote-api-bridge`:讀到一行請求才轉給 socket)。
        case afterStdinLine
    }

    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int32
    public var trigger: Trigger
    /// 送出 stdout 後不結束(像 `events.subscribe` 的串流),之後由測試 `send`／`finish`。
    public var keepsOpen: Bool

    public init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32 = 0, trigger: Trigger = .immediately, keepsOpen: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.trigger = trigger
        self.keepsOpen = keepsOpen
    }

    /// 回放錄製的 `herdr remote-api-bridge` 回應(`Fixtures/herdr-<版本>/<檔名>`):等請求那一行到了才回。
    public static func recorded(_ fixture: String, herdr version: String = Fixtures.defaultHerdrVersion, keepsOpen: Bool = false) -> FakeReply {
        FakeReply(stdout: Fixtures.data(fixture, herdr: version), trigger: .afterStdinLine, keepsOpen: keepsOpen)
    }

    /// 回放錄製回應的**第一行**,先以 `modify` 改動其中的 JSON。
    ///
    /// 用在真實主機錄不到的情境(例如 herdr 0.9.5 不會送出的欄位、難以觸發的錯誤):以真實回應為底，
    /// 只改測試關心的那幾個值，改了什麼寫在測試裡，一眼看得出不是原樣錄製。
    public static func recorded(
        _ fixture: String, herdr version: String = Fixtures.defaultHerdrVersion,
        modify: (inout [String: Any]) -> Void
    ) -> FakeReply {
        FakeReply(stdout: Fixtures.modifiedLine(fixture, herdr: version, modify: modify), trigger: .afterStdinLine)
    }
}

public enum FakeHostError: Error, Equatable {
    case unexpectedCommand(String)
    case unexpectedPTY(PTYRequest)
    case writeAfterClose
}

private struct FakeExecSession: ExecSession {
    let host: FakeHost
    let id: Int
    let output: AsyncThrowingStream<ExecOutput, any Error>

    func write(_ data: Data) async throws { try await host.received(data, for: id) }
    func closeStdin() async { await host.closedStdin(for: id) }
    func close() async { await host.closed(id) }
}

private struct FakePTYSession: PTYSession {
    let host: FakeHost
    let id: Int
    let output: AsyncThrowingStream<Data, any Error>
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    func write(_ data: Data) async throws { await host.ptyReceived(data, for: id) }
    func resize(columns: Int, rows: Int) async throws { await host.ptyResized(id, columns: columns, rows: rows) }
    func close() async {
        continuation.finish()
        await host.ptyClosed(id)
    }
}
