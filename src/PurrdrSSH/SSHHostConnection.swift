import Foundation
import PurrdrCore

/// SSH 連線方式的主機連線：包住主機通道，herdr 請求經 `herdr remote-api-bridge`,對話紀錄與 Pane 終端機執行主機指令。
///
/// Demo 主機與假主機也是主機通道(回應同樣的指令字串),所以同樣經過這裡。
public struct SSHHostConnection: HostConnection {
    private let channel: any HostChannel
    private let herdr: HerdrInstallation
    /// 期限計時用(測試注入)。
    private let sleep: Sleep
    /// 對話紀錄追蹤的長駐通道(#166);這個連線的複本共用。
    private let follower: SSHTranscriptFollower

    /// - Parameter followDiagnostics: 對話紀錄追蹤退回輪詢時的原因(交給系統紀錄)。
    public init(
        channel: any HostChannel, herdr: HerdrInstallation = HerdrInstallation(), sleep: @escaping Sleep = Sleeping.task,
        followDiagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        self.channel = channel
        self.herdr = herdr
        self.sleep = sleep
        follower = SSHTranscriptFollower(channel: channel, sleep: sleep, diagnostics: followDiagnostics)
    }

    public func disconnect() async {
        await follower.close()
        await channel.disconnect()
    }

    /// keepalive 改用短間隔(聊天畫面可見時)。
    public func beginQuickDisconnectDetection() async {
        await channel.beginQuickDisconnectDetection()
    }

    public func endQuickDisconnectDetection() async {
        await channel.endQuickDisconnectDetection()
    }

    // MARK: - herdr 單次請求

    /// 開一個 bridge、寫一行請求、**不送 EOF**,讀到第一行回應後關閉通道(行為規格 §3.3)。
    /// 經一次性指令的入口(`runOnce`):期限到丟 `HerdrError.deadlineExceeded`(§7.2)。
    public func herdrRequest(_ original: Data, deadline: Duration) async throws -> Data {
        // 續接(#535):`sessions.list` 與 `agent.start` 的 `resume_session` 是主機服務的訊息,在這裡換成主機上的做法。
        let request: Data
        switch try SSHResumeRequest(original) {
        case .passthrough: request = original
        case .rewritten(let rewritten): request = rewritten
        case .sessionsList(let requestID, let cwd, let kind):
            let sessions = try await SSHSessionHistory(channel: channel, sleep: sleep).sessions(cwd: cwd, kind: kind, deadline: deadline)
            return try SSHResumeRequest.sessionsListResponse(requestID: requestID, sessions: sessions)
        }
        do {
            return try await channel.runOnce(HerdrCommand.bridge(herdr), deadline: deadline, sleep: sleep) { session in
                try await session.write(request)
                return try await Self.firstLine(of: session)
            }
        } catch HostCommandError.deadlineExceeded {
            throw HerdrError.deadlineExceeded
        }
    }

    /// 讀到 stdout 的第一行就停。stdout 沒有任何內容就結束時，帶上 exit code 與 stderr 回報。
    private static func firstLine(of session: any ExecSession) async throws -> Data {
        let result = try await session.read { $0.contains(0x0A) }
        if let newline = result.stdout.firstIndex(of: 0x0A) { return Data(result.stdout[result.stdout.startIndex..<newline]) }
        // herdr 失敗時可能把錯誤 envelope 印在 stderr(行為規格 §3.2)。
        if result.stdout.isEmpty, let envelope = errorEnvelope(in: result.stderr) { return envelope }
        // bridge 連不到 socket = 這個 session 沒有在跑 herdr(行為規格 §3.3)。
        let stderrText = String(decoding: result.stderr, as: UTF8.self)
        if result.stdout.isEmpty, stderrText.contains("failed to connect to remote Herdr API socket") {
            throw HerdrError.herdr(code: "server_not_running", message: stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !result.stdout.isEmpty else {
            throw HerdrError.noResponse(exitCode: result.exitStatus, stderr: stderrText)
        }
        return result.stdout
    }

    private static func errorEnvelope(in stderr: Data) -> Data? {
        stderr.split(separator: 0x0A).first(where: { $0.first == UInt8(ascii: "{") }).map { Data($0) }
    }

    // MARK: - Agent 事件串流

    /// 跟單次請求一樣開 bridge、寫一行、**不送 EOF**(bridge 在 EOF 時只回 ack 就結束);之後逐行轉出 stdout,
    /// 直到主機那端結束或呼叫端不再讀(此時關閉通道)。stdout 一行都沒有就結束時，先轉出 stderr 的錯誤 envelope,
    /// 再丟 `HerdrError.noResponse`(行為規格 §3.7)。
    public func herdrEvents(_ request: Data) async throws -> AsyncThrowingStream<Data, any Error> {
        let session = try await channel.execute(HerdrCommand.bridge(herdr))
        do {
            try await session.write(request)
        } catch {
            await session.close()
            throw error
        }
        let (lines, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let reader = Task {
            do {
                try await Self.readLines(from: session, into: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            await session.close()
        }
        continuation.onTermination = { _ in
            reader.cancel()
            Task { await session.close() }
        }
        return lines
    }

    private static func readLines(from session: any ExecSession, into continuation: AsyncThrowingStream<Data, any Error>.Continuation) async throws {
        var sawLine = false
        let result = try await session.read { buffer in
            while let newline = buffer.firstIndex(of: 0x0A) {
                continuation.yield(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
                sawLine = true
            }
            return false
        }
        guard !sawLine else { return }
        if let envelope = errorEnvelope(in: result.stderr) { continuation.yield(envelope) }
        throw HerdrError.noResponse(exitCode: result.exitStatus, stderr: String(decoding: result.stderr, as: UTF8.self))
    }

    // MARK: - 對話紀錄

    /// 執行對話紀錄指令並收集 stdout;依 exit code 判斷，不比對 stderr 文字(R-S15)。
    /// 期限(`TranscriptPlan`)到了丟 `HostCommandError.deadlineExceeded`。
    public func readTranscript(_ request: TranscriptRequest) async throws -> Data {
        let plan = TranscriptPlan(request)
        let result = try await channel.runOnce(plan.command, deadline: plan.deadline, sleep: sleep) { session in
            try await session.read()
        }
        if let error = TranscriptReadError(exitStatus: result.exitStatus) { throw error }
        return result.stdout
    }

    /// 追蹤對話紀錄尾端：照 `pace` 經長駐通道問主機，沒變不送事件(#166)。主機跑不了追蹤腳本時退回分段接著讀的輪詢。
    public func followTranscript(path: String, from cursor: Int, pace: TranscriptFollowPace) async -> AsyncThrowingStream<TranscriptFollowEvent, any Error> {
        let (events, continuation) = AsyncThrowingStream<TranscriptFollowEvent, any Error>.makeStream()
        let following = Task { [follower] in
            await follower.started()
            do {
                try await Self.follow(path: path, from: cursor, pace: pace, follower: follower, connection: self, into: continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            await follower.stopped()
        }
        continuation.onTermination = { _ in following.cancel() }
        return events
    }

    private static func follow(
        path: String, from cursor: Int, pace: TranscriptFollowPace, follower: SSHTranscriptFollower, connection: SSHHostConnection,
        into continuation: AsyncThrowingStream<TranscriptFollowEvent, any Error>.Continuation
    ) async throws {
        var position = SSHTranscriptFollower.Position(cursor: cursor)
        while true {
            try await pace.wait()
            switch try await follower.poll(path: path, from: position) {
            case .unsupported:
                pace.wake()
                for try await event in TranscriptPolling.follow(connection: connection, path: path, from: position.cursor, pace: pace) {
                    continuation.yield(event)
                }
                return
            case .reply(.unchanged):
                continue
            case .reply(.read(_, let stamp, let lines, let end, let anchor)):
                guard end >= position.cursor else { throw TranscriptReadError.changed }
                if !lines.isEmpty {
                    continuation.yield(.appended(TranscriptChunk(start: position.cursor, end: end, lines: lines)))
                }
                position = SSHTranscriptFollower.Position(cursor: end, stamp: stamp, anchor: anchor)
            case .reply(.replaced(let size)):
                continuation.yield(.replaced(size: size))
                return
            case .reply(.failed(let exitCode)):
                throw TranscriptReadError(exitStatus: exitCode) ?? .changed
            }
        }
    }

    // MARK: - Pane 終端機

    /// 執行 `herdr terminal session control`(ADR-0005)。
    public func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection {
        let command = HerdrCommand.terminalSessionControl(target: target, columns: columns, rows: rows, takeover: takeover, herdr: herdr)
        return PaneTerminalConnection(session: try await channel.execute(command))
    }
}

/// 一次對話紀錄讀取的主機指令與期限(同一個 switch 決定，不會一邊漏改)。
struct TranscriptPlan {
    let command: String
    /// 視窗、追蹤與列表預覽依讀取上限加上傳輸時間;其他是預設的 20 秒。
    let deadline: Duration

    init(_ request: TranscriptRequest) {
        switch request {
        case .locate(let location):
            command = TranscriptCommand.locate(location)
            deadline = HostCommandDeadline.standard
        case .window(let path, let end, let lines, let chunkBytes, let maxBytes):
            command = TranscriptCommand.window(path: path, end: end, lines: lines, chunkBytes: chunkBytes, maxBytes: maxBytes)
            deadline = HostCommandDeadline.transfer(bytes: maxBytes > 0 ? min(chunkBytes, maxBytes) : chunkBytes)
        case .tail(let path, let cursor, let limit):
            command = TranscriptCommand.tail(path: path, from: cursor, limit: limit)
            deadline = HostCommandDeadline.transfer(bytes: limit)
        case .catchUp(let path, let cursor, let limit):
            command = TranscriptCommand.catchUp(path: path, from: cursor, limit: limit)
            // 超過上限的單行在主機端截短到上限，所以傳輸量不超過 `limit`(#130)。
            deadline = HostCommandDeadline.transfer(bytes: limit)
        case .previews(let marker, let requests):
            command = TranscriptCommand.previews(marker: marker, entries: requests.compactMap(TranscriptCommand.PreviewEntry.init))
            deadline = HostCommandDeadline.transfer(bytes: requests.count * TranscriptCommand.previewBytes)
        case .findSubagent(let sessionFolder, let callID):
            command = TranscriptCommand.findSubagent(sessionFolder: sessionFolder, callID: callID)
            deadline = HostCommandDeadline.standard
        case .readWorkflow(let sessionFolder, let runID, let knownChecksum):
            command = TranscriptCommand.readWorkflow(sessionFolder: sessionFolder, runID: runID, knownChecksum: knownChecksum)
            deadline = HostCommandDeadline.standard
        case .delegationLines(let path, let callID, let agentID, let knownChecksum):
            command = TranscriptCommand.delegationLines(path: path, ids: (callID, agentID), knownChecksum: knownChecksum)
            deadline = HostCommandDeadline.standard
        }
    }
}
