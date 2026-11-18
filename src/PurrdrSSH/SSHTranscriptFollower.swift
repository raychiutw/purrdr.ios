import Foundation
import PurrdrCore
#if canImport(os)
import os
#endif

/// SSH 的對話紀錄追蹤(#166):每台主機一條長駐 exec 通道跑 `TranscriptCommand.follow`,所有追蹤中的路徑共用、一次一個請求。
///
/// 通道結束(自我時限、背景被殺)時游標留在各追蹤裡，下一個請求重開通道;沒回應就結束的依次數退避再重開。
/// 只有明確訊號(還沒回應就 exit 127 找不到指令;Windows 方言認不得)才回報 `unsupported`,由呼叫端退回分段接著讀的輪詢。
actor SSHTranscriptFollower {
    /// 一個追蹤的位置：游標、主機上次回報的版本與游標前一段的錨點(不知道時是 `-`)。
    struct Position: Sendable, Equatable {
        var cursor: Int
        var stamp = "-"
        var anchor = "-"
    }

    enum Reply: Sendable, Equatable {
        case unchanged
        /// 版本變了;`lines` 可能是空的(只有還沒寫完的行)。`size` 是主機上的檔案大小。
        case read(size: Int, stamp: String, lines: [String], end: Int, anchor: String)
        case replaced(size: Int)
        case failed(exitCode: Int32)
    }

    enum Poll: Sendable, Equatable {
        case reply(Reply)
        case unsupported
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
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var followers = 0

    init(channel: any HostChannel, command: String = TranscriptCommand.follow(), sleep: @escaping Sleep) {
        self.channel = channel
        self.command = command
        deadline = HostCommandDeadline.transfer(bytes: TranscriptReader.catchUpBacklogLimit)
        self.sleep = sleep
    }

    /// 開始一個追蹤。
    func started() {
        followers += 1
    }

    /// 一個追蹤結束;最後一個結束時關閉通道(腳本讀到 EOF 就結束)。
    func stopped() {
        followers -= 1
        if followers <= 0, !isBusy { closeSession() }
    }

    /// 斷線：關閉通道。等回應中的請求在新通道重問一次。
    func close() {
        closeSession(failing: ChannelEnded(exitCode: nil, hadReplied: true))
    }

    /// 問主機 `path` 從 `position` 之後有沒有變化。通道在回應前結束時重開再問一次。
    func poll(path: String, from position: Position) async throws -> Poll {
        await acquire()
        defer { release() }
        if isUnsupported { return .unsupported }
        let request = Data("\(position.cursor) \(position.stamp) \(position.anchor) \(path)\n".utf8)
        for attempt in 0..<2 {
            do {
                return .reply(Self.dropsStampIfCapped(try await send(request, on: try await openSession()), from: position.cursor))
            } catch let ended as ChannelEnded {
                closeSession()
                if !ended.hadReplied, ended.exitCode != Int32(HostScriptTimeLimit.exitCode) { consecutiveFailures += 1 }
                if !ended.hadReplied, ended.exitCode == Self.commandNotFoundExitCode {
                    fallBack(because: "exit \(Self.commandNotFoundExitCode) before any reply")
                    return .unsupported
                }
                if attempt == 1 { throw TranscriptReadError.failed(exitCode: ended.exitCode) }
            } catch WindowsCommandError.unsupported {
                fallBack(because: "Windows dialect can’t run the follow script")
                return .unsupported
            } catch {
                closeSession()
                throw error
            }
        }
        throw TranscriptReadError.changed
    }

    /// sh 找不到指令的 exit code(Demo 主機也回它)。
    static let commandNotFoundExitCode: Int32 = 127

    /// 重開通道前的退避：1 秒起倍增、上限 30 秒。
    static func reopenBackoff(afterFailures failures: Int) -> Duration {
        .seconds(min(30, 1 << min(failures - 1, 5)))
    }

    /// 之後一律退回輪詢，並記下原因。
    private func fallBack(because reason: String) {
        isUnsupported = true
        #if canImport(os)
        Logger(subsystem: "com.raychiu.purrdr", category: "transcript-follow").notice("follow script unsupported, polling instead: \(reason, privacy: .public)")
        #endif
    }

    // MARK: - 一次一個請求

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty {
            isBusy = false
            if followers <= 0 { closeSession() }
        } else {
            queue.removeFirst().resume()
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

    private func send(_ request: Data, on session: any ExecSession) async throws -> Reply {
        let current = generation
        do {
            try await session.write(request)
        } catch {
            // 通道已經結束(例如主機沒有這支腳本):照結束處理。
            if current == generation, let endedError { throw endedError }
            throw error
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
            guard let parsed = try Self.takeReply(from: &buffer) else { return }
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

    // MARK: - 回應格式(`TranscriptCommand.follow`)

    /// 落後超過一次讀的上限時，主機可能只讀了一部分：不留版本，否則下一輪只拿到 `unchanged`,剩下的要等檔案再變才送。
    /// 沒超過時剩下的只是還沒寫完的行，留著版本(沒變只回 `unchanged`)。
    static func dropsStampIfCapped(_ reply: Reply, from cursor: Int) -> Reply {
        guard case .read(let size, _, let lines, let end, let anchor) = reply, size - cursor > TranscriptReader.catchUpBacklogLimit else { return reply }
        return .read(size: size, stamp: "-", lines: lines, end: end, anchor: anchor)
    }

    /// 從 `buffer` 取出一則完整的回應;還不完整回傳 `nil`。格式不對丟 `TranscriptReadError.changed`。
    static func takeReply(from buffer: inout Data) throws -> Reply? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let words = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self).split(separator: " ").map(String.init)
        let afterHeader = buffer.index(after: newline)
        switch (words.first, words.count) {
        case ("unchanged", 1):
            buffer.removeSubrange(..<afterHeader)
            return .unchanged
        case ("replaced", 2):
            guard let size = Int(words[1]) else { throw TranscriptReadError.changed }
            buffer.removeSubrange(..<afterHeader)
            return .replaced(size: size)
        case ("error", 2):
            guard let code = Int32(words[1]) else { throw TranscriptReadError.changed }
            buffer.removeSubrange(..<afterHeader)
            return .failed(exitCode: code)
        case ("appended", 3):
            // 每行紀錄以數字開頭，所以「end 」開頭的只會是結尾那行。
            var lineStart = afterHeader
            while let lineEnd = buffer[lineStart...].firstIndex(of: 0x0A) {
                guard buffer[lineStart..<lineEnd].starts(with: Data("end ".utf8)) else {
                    lineStart = buffer.index(after: lineEnd)
                    continue
                }
                let trailer = String(decoding: buffer[lineStart..<lineEnd], as: UTF8.self).split(separator: " ").map(String.init)
                guard trailer.count == 3, let end = Int(trailer[1]) else { throw TranscriptReadError.changed }
                guard let size = Int(words[1]) else { throw TranscriptReadError.changed }
                let records = try TranscriptReader.records(buffer[afterHeader..<lineStart])
                buffer.removeSubrange(..<buffer.index(after: lineEnd))
                return .read(size: size, stamp: words[2], lines: records.lines, end: end, anchor: trailer[2])
            }
            return nil
        default:
            throw TranscriptReadError.changed
        }
    }
}
