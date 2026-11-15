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
    private var ptyExpectations: [(request: PTYRequest, output: Data)] = []
    private var pending: [Int: (reply: FakeReply, continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation)] = [:]

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

    public func execute(_ command: String) async throws -> any ExecSession {
        guard let index = expectations.firstIndex(where: { $0.command == command }) else {
            throw FakeHostError.unexpectedCommand(command)
        }
        let reply = expectations.remove(at: index).reply
        let id = executions.count
        executions.append(Execution(command: command, stdin: Data(), closedStdin: false, closed: false))
        let (stream, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
        if reply.trigger == .immediately {
            Self.emit(reply, to: continuation)
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
        return FakePTYSession(host: self, id: id, output: stream, continuation: continuation)
    }

    /// 對第 `index` 個執行(`executions` 的索引,`.manual` 回應)送出一個輸出事件。
    public func send(_ output: ExecOutput, toExecution index: Int) {
        pending[index]?.continuation.yield(output)
    }

    /// 對第 `index` 個執行(`.manual` 回應)送出結束狀態並結束串流。
    public func finish(execution index: Int, exitCode: Int32 = 0) {
        guard let waiting = pending.removeValue(forKey: index) else { return }
        waiting.continuation.yield(.exit(code: exitCode))
        waiting.continuation.finish()
    }

    /// 等到 app 執行了 `count` 個指令(測試與 app 的非同步工作對齊用)。逾時則回傳目前數量。
    public func waitForExecutions(_ count: Int, timeout: Duration = .seconds(2)) async -> Int {
        let deadline = ContinuousClock.now + timeout
        while executions.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return executions.count
    }

    /// 等到第 `index` 個執行的 stdin 滿足 `condition`。逾時則回傳 `false`。
    public func waitForStdin(
        ofExecution index: Int, timeout: Duration = .seconds(2), until condition: @Sendable (Execution) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if index < executions.count, condition(executions[index]) { return true }
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
            Self.emit(waiting.reply, to: waiting.continuation)
        }
    }

    fileprivate func closedStdin(for id: Int) {
        executions[id].closedStdin = true
        if pending[id]?.reply.trigger == .manual { return }
        // 真的 bridge 在 stdin 一行都沒收到就 EOF 時，什麼都不回、exit 0(行為規格 §3.3)。
        if let waiting = pending.removeValue(forKey: id) {
            waiting.continuation.yield(.exit(code: 0))
            waiting.continuation.finish()
        }
    }

    fileprivate func closed(_ id: Int) {
        executions[id].closed = true
        pending.removeValue(forKey: id)?.continuation.finish()
    }

    fileprivate func ptyReceived(_ data: Data, for id: Int) { ptys[id].input.append(data) }
    fileprivate func ptyResized(_ id: Int, columns: Int, rows: Int) { ptys[id].sizes.append(.init(columns: columns, rows: rows)) }
    fileprivate func ptyClosed(_ id: Int) { ptys[id].closed = true }

    private static func emit(_ reply: FakeReply, to continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation) {
        if !reply.stdout.isEmpty { continuation.yield(.stdout(reply.stdout)) }
        if !reply.stderr.isEmpty { continuation.yield(.stderr(reply.stderr)) }
        continuation.yield(.exit(code: reply.exitCode))
        continuation.finish()
    }
}

/// 假主機對一個指令的回應。
public struct FakeReply: Sendable {
    public enum Trigger: Sendable {
        /// 指令一開始就回應(一般指令)。
        case immediately
        /// 等 stdin 收到第一個換行才回應(`herdr remote-api-bridge`:讀到一行請求才轉給 socket)。
        case afterStdinLine
        /// 什麼都不自動送;由測試以 `FakeHost.send(_:toExecution:)`／`finish(execution:exitCode:)` 逐步送出
        /// (`herdr terminal session control` 這種長時間串流)。
        case manual
    }

    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int32
    public var trigger: Trigger

    public init(stdout: Data = Data(), stderr: Data = Data(), exitCode: Int32 = 0, trigger: Trigger = .immediately) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.trigger = trigger
    }

    /// 回放錄製的 `herdr remote-api-bridge` 回應(`Fixtures/herdr-<版本>/<檔名>`):等請求那一行到了才回。
    public static func recorded(_ fixture: String, herdr version: String = Fixtures.defaultHerdrVersion) -> FakeReply {
        FakeReply(stdout: Fixtures.data(fixture, herdr: version), trigger: .afterStdinLine)
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
