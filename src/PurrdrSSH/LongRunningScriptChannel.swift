import Foundation
import PurrdrCore

/// 每台主機一條長駐 exec 通道跑一支有自我時限的腳本：請求一行、回應一則，一次一個(#166、#203)。
/// 通道結束就重開(沒回應的依次數退避);主機跑不了腳本時回 `.unsupported`,由呼叫端退回一次性讀取。
actor LongRunningScriptChannel<Reply: Sendable> {
    enum Outcome: Sendable {
        case reply(Reply)
        case unsupported
    }

    /// 通道在回應前結束兩次;`exitCode` 是第二條的結束狀態。
    struct Ended: Error {
        var exitCode: Int32?
    }

    /// 通道在回應前結束。
    private struct ChannelEnded: Error {
        var exitCode: Int32?
        var hadReplied: Bool
    }

    private let channel: any HostChannel
    private let command: String
    private let deadline: Duration
    private let sleep: Sleep
    /// 從緩衝取出一則完整的回應;還不完整回傳 `nil`,格式不對丟錯(通道關閉)。
    private let takeReply: @Sendable (inout Data) throws -> Reply?
    /// 最後一個使用者結束時關閉通道;`false` 時通道留著，靠腳本的閒置時限結束。
    private let closesWhenUnused: Bool
    private let diagnostics: (@Sendable (String) -> Void)?
    private let name: String

    private var isUnsupported = false
    /// 連續幾條通道沒回應就結束(不含自我時限);重開前依此退避。
    private var consecutiveFailures = 0
    private var session: (any ExecSession)?
    private var reader: Task<Void, Never>?
    /// 每開一條通道加一;舊通道晚到的輸出不理。
    private var generation = 0
    private var buffer = Data()
    private var hasReplied = false
    private var waiting: CheckedContinuation<Reply, any Error>?
    /// 目前這條通道已經結束(還沒有人等回應時)。
    private var endedError: (any Error)?
    private var isBusy = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var users = 0

    init(
        name: String, channel: any HostChannel, command: String, deadline: Duration, sleep: @escaping Sleep, closesWhenUnused: Bool,
        diagnostics: (@Sendable (String) -> Void)?, takeReply: @escaping @Sendable (inout Data) throws -> Reply?
    ) {
        self.name = name
        self.channel = channel
        self.command = command
        self.deadline = deadline
        self.sleep = sleep
        self.closesWhenUnused = closesWhenUnused
        self.diagnostics = diagnostics
        self.takeReply = takeReply
    }

    func started() {
        users += 1
    }

    /// 最後一個使用者結束時關閉通道(腳本讀到 EOF 就結束)。
    func stopped() {
        users -= 1
        if closesWhenUnused, users <= 0, !isBusy { closeSession() }
    }

    /// 斷線：關閉通道。等回應中的請求在新通道重問一次。
    func close() {
        closeSession(failing: ChannelEnded(exitCode: nil, hadReplied: true))
    }

    /// 送一行請求(含換行)。通道在回應前結束時重開再問一次，第二次也結束丟 `Ended`。
    func request(_ line: Data, deadline overridden: Duration? = nil) async throws -> Outcome {
        await acquire()
        defer { release() }
        return try await perform(line, deadline: overridden ?? deadline)
    }

    /// 通道正忙(別的請求還沒回應)時不排隊,回 `nil`,呼叫端退回一次性指令(#662)。
    func requestIfIdle(_ line: Data, deadline overridden: Duration? = nil) async throws -> Outcome? {
        guard !isBusy else { return nil }
        return try await request(line, deadline: overridden)
    }

    /// 這支腳本是否已確定跑不了(之後的請求直接回 `.unsupported`)。
    var isKnownUnsupported: Bool { isUnsupported }

    private func perform(_ line: Data, deadline: Duration) async throws -> Outcome {
        if isUnsupported { return .unsupported }
        for attempt in 0..<2 {
            do {
                return .reply(try await send(line, deadline: deadline, on: try await openSession()))
            } catch let ended as ChannelEnded {
                closeSession()
                if !ended.hadReplied, ended.exitCode != Int32(HostScriptTimeLimit.exitCode) { consecutiveFailures += 1 }
                if !ended.hadReplied, let exitCode = ended.exitCode, Self.unsupportedExitCodes.contains(exitCode) {
                    fallBack(because: "exit \(exitCode) before any reply")
                    return .unsupported
                }
                if attempt == 1 { throw Ended(exitCode: ended.exitCode) }
            } catch WindowsCommandError.unsupported {
                fallBack(because: "Windows dialect can’t run the script")
                return .unsupported
            } catch {
                closeSession()
                throw error
            }
        }
        throw Ended(exitCode: nil)
    }

    /// 還沒回應就以這些結束 = 跑不了長駐腳本：127 找不到指令(Demo 主機也回它)、0 是 stdin 一開始就結束。
    static var unsupportedExitCodes: Set<Int32> { [127, 0] }

    /// 重開通道前的退避：1 秒起倍增、上限 30 秒。
    static func reopenBackoff(afterFailures failures: Int) -> Duration {
        .seconds(min(30, 1 << min(failures - 1, 5)))
    }

    private func fallBack(because reason: String) {
        isUnsupported = true
        diagnostics?("\(name) script unsupported, falling back: \(reason)")
    }

    // MARK: - 一次一個請求

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    private func release() {
        if requestWaiters.isEmpty {
            isBusy = false
            if closesWhenUnused, users <= 0 { closeSession() }
        } else {
            requestWaiters.removeFirst().resume()
        }
    }

    // MARK: - 通道

    private func openSession() async throws -> any ExecSession {
        if let session { return session }
        if consecutiveFailures > 0 { try await sleep(Self.reopenBackoff(afterFailures: consecutiveFailures)) }
        let opened = try await channel.execute(command)
        generation += 1
        let current = generation
        session = opened
        buffer = Data()
        hasReplied = false
        endedError = nil
        reader = Task { [weak self] in
            var exitCode: Int32?
            do {
                for try await event in opened.output {
                    switch event {
                    case .stdout(let data): await self?.received(data, generation: current)
                    case .exit(let code, _): exitCode = code
                    case .stderr: break
                    }
                }
                await self?.ended(generation: current, throwing: nil, exitCode: exitCode)
            } catch {
                await self?.ended(generation: current, throwing: error, exitCode: exitCode)
            }
        }
        return opened
    }

    /// 關閉通道;還在等回應的請求以 `error` 結束。
    private func closeSession(failing error: any Error = CancellationError()) {
        if let waiting {
            self.waiting = nil
            waiting.resume(throwing: error)
        }
        generation += 1
        reader?.cancel()
        reader = nil
        if let session {
            Task { await session.close() }
        }
        session = nil
        buffer = Data()
    }

    private func send(_ request: Data, deadline: Duration, on session: any ExecSession) async throws -> Reply {
        let current = generation
        do {
            try await session.write(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 通道已經結束(例如主機沒有這支腳本):照結束處理。
            if current == generation, let endedError { throw endedError }
            // 腳本已結束但結束狀態還沒送到(閒置到時限，broken pipe):同樣當通道結束，重開再問。
            throw ChannelEnded(exitCode: nil, hadReplied: hasReplied)
        }
        let timer = Task { [sleep, deadline, weak self] in
            guard (try? await sleep(deadline)) != nil, !Task.isCancelled else { return }
            await self?.abandon(generation: current, throwing: HostCommandError.deadlineExceeded)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard current == generation, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiting = continuation
                deliverReply()
                if let endedError, let waiting {
                    self.waiting = nil
                    waiting.resume(throwing: endedError)
                }
            }
        } onCancel: {
            Task { await self.abandon(generation: current, throwing: CancellationError()) }
        }
    }

    /// 期限到或呼叫端取消：交出錯誤並關閉通道(晚到的回應不能交給下一個請求)。
    private func abandon(generation current: Int, throwing error: any Error) {
        guard current == generation, let waiting else { return }
        self.waiting = nil
        waiting.resume(throwing: error)
        closeSession()
    }

    private func received(_ data: Data, generation current: Int) {
        guard current == generation else { return }
        buffer.append(data)
        deliverReply()
    }

    private func ended(generation current: Int, throwing error: (any Error)?, exitCode: Int32?) {
        guard current == generation else { return }
        session = nil
        reader = nil
        let failure = error ?? ChannelEnded(exitCode: exitCode, hadReplied: hasReplied)
        guard let waiting else {
            endedError = failure
            return
        }
        self.waiting = nil
        waiting.resume(throwing: failure)
    }

    private func deliverReply() {
        guard let waiting else { return }
        let reply: Reply
        do {
            guard let parsed = try takeReply(&buffer) else { return }
            reply = parsed
        } catch {
            self.waiting = nil
            waiting.resume(throwing: error)
            closeSession()
            return
        }
        hasReplied = true
        consecutiveFailures = 0
        self.waiting = nil
        waiting.resume(returning: reply)
    }
}
