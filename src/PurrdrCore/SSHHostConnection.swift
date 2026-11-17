import Foundation

/// SSH 連線方式的主機連線：包住主機通道，herdr 請求經 `herdr remote-api-bridge`,對話紀錄與 Pane 終端機執行主機指令。
///
/// Demo 主機與假主機也是主機通道(回應同樣的指令字串),所以同樣經過這裡。
public struct SSHHostConnection: HostConnection {
    private let channel: any HostChannel
    private let herdr: HerdrInstallation
    /// 期限計時用(測試注入)。
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        channel: any HostChannel, herdr: HerdrInstallation = HerdrInstallation(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.channel = channel
        self.herdr = herdr
        self.sleep = sleep
    }

    public func disconnect() async {
        await channel.disconnect()
    }

    // MARK: - herdr 單次請求

    /// 開一個 bridge、寫一行請求、**不送 EOF**,讀到第一行回應後關閉通道(行為規格 §3.3)。
    public func herdrRequest(_ request: Data, deadline: Duration?) async throws -> Data {
        let session = try await channel.execute(HerdrCommand.bridge(herdr))
        let line: Data
        do {
            try await session.write(request)
            if let deadline {
                line = try await Self.firstLine(of: session, within: deadline, sleep: sleep)
            } else {
                line = try await Self.firstLine(of: session)
            }
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        return line
    }

    /// 在期限內讀第一行;期限先到就關閉通道並丟 `HerdrError.deadlineExceeded`(§7.2)。
    private static func firstLine(
        of session: any ExecSession, within deadline: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await firstLine(of: session) }
            group.addTask {
                try await sleep(deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let line = first else {
                await session.close()
                throw HerdrError.deadlineExceeded
            }
            return line
        }
    }

    /// 讀到 stdout 的第一行就停。stdout 沒有任何內容就結束時，帶上 exit code 與 stderr 回報。
    private static func firstLine(of session: any ExecSession) async throws -> Data {
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32?
        for try await event in session.output {
            switch event {
            case .stdout(let data):
                stdout.append(data)
                if let newline = stdout.firstIndex(of: 0x0A) { return stdout[stdout.startIndex..<newline] }
            case .stderr(let data):
                stderr.append(data)
            case .exit(let code, _):
                exitCode = code
            }
        }
        // herdr 失敗時可能把錯誤 envelope 印在 stderr(行為規格 §3.2)。
        if stdout.isEmpty, let envelope = errorEnvelope(in: stderr) { return envelope }
        // bridge 連不到 socket = 這個 session 沒有在跑 herdr(行為規格 §3.3)。
        let stderrText = String(decoding: stderr, as: UTF8.self)
        if stdout.isEmpty, stderrText.contains("failed to connect to remote Herdr API socket") {
            throw HerdrError.herdr(code: "server_not_running", message: stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !stdout.isEmpty else {
            throw HerdrError.noResponse(exitCode: exitCode, stderr: stderrText)
        }
        return stdout
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
        var buffer = Data()
        var stderr = Data()
        var exitCode: Int32?
        var sawLine = false
        for try await output in session.output {
            switch output {
            case .stdout(let data):
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    continuation.yield(Data(buffer[buffer.startIndex..<newline]))
                    buffer.removeSubrange(buffer.startIndex...newline)
                    sawLine = true
                }
            case .stderr(let data):
                stderr.append(data)
            case .exit(let code, _):
                exitCode = code
            }
        }
        guard !sawLine else { return }
        if let envelope = errorEnvelope(in: stderr) { continuation.yield(envelope) }
        throw HerdrError.noResponse(exitCode: exitCode, stderr: String(decoding: stderr, as: UTF8.self))
    }

    // MARK: - 對話紀錄

    /// 執行對話紀錄指令並收集 stdout;依 exit code 判斷，不比對 stderr 文字(R-S15)。
    public func readTranscript(_ request: TranscriptRequest) async throws -> Data {
        let session = try await channel.execute(Self.command(for: request))
        var stdout = Data()
        var exitCode: Int32?
        do {
            for try await event in session.output {
                switch event {
                case .stdout(let data): stdout.append(data)
                case .stderr: break
                case .exit(let code, _): exitCode = code
                }
            }
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        switch exitCode {
        case 0?: return stdout
        case 3?: throw TranscriptReadError.absent
        case 4?, 5?: throw TranscriptReadError.unreadable
        case 6?: throw TranscriptReadError.ambiguous
        case 7?: throw TranscriptReadError.compressed
        default: throw TranscriptReadError.failed(exitCode: exitCode)
        }
    }

    static func command(for request: TranscriptRequest) -> String {
        switch request {
        case .locateClaude(let sessionID, let projectFolder):
            TranscriptCommand.locate(sessionID: sessionID, projectFolder: projectFolder)
        case .locate(let location, let readsHeader):
            TranscriptCommand.locate(location, readsHeader: readsHeader)
        case .window(let path, let end, let lines, let chunkBytes):
            TranscriptCommand.window(path: path, end: end, lines: lines, chunkBytes: chunkBytes)
        case .tail(let path, let cursor, let limit):
            TranscriptCommand.tail(path: path, from: cursor, limit: limit)
        case .previews(let marker, let requests):
            TranscriptCommand.previews(marker: marker, entries: requests.compactMap(TranscriptCommand.PreviewEntry.init))
        case .findSubagent(let sessionFolder, let callID):
            TranscriptCommand.findSubagent(sessionFolder: sessionFolder, callID: callID)
        case .readWorkflow(let sessionFolder, let runID, let knownChecksum):
            TranscriptCommand.readWorkflow(sessionFolder: sessionFolder, runID: runID, knownChecksum: knownChecksum)
        case .delegationLines(let path, let callID, let agentID, let knownChecksum):
            TranscriptCommand.delegationLines(path: path, ids: (callID, agentID), knownChecksum: knownChecksum)
        }
    }

    // MARK: - Pane 終端機

    /// 執行 `herdr terminal session control`(ADR-0005)。
    public func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection {
        let command = HerdrCommand.terminalSessionControl(target: target, columns: columns, rows: rows, takeover: takeover, herdr: herdr)
        return PaneTerminalConnection(session: try await channel.execute(command))
    }
}
