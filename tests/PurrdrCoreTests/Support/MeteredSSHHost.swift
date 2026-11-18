import Foundation
import PurrdrCore
import PurrdrSSH
import PurrdrTestSupport

#if os(macOS)

/// 計量的 SSH 主機通道(流量守門，#168):herdr bridge 由這裡依目前的 Agent 狀態回放錄製的回應，
/// 對話紀錄指令交給 `LocalShellHost` 在本機實跑。每條 exec 通道記下種類與兩個方向的位元組。
actor MeteredSSHHost: HostChannel {
    /// 一條 exec 通道。
    struct Exchange: Sendable {
        /// herdr method(`session.snapshot` 等)或對話紀錄指令的種類(`transcript.follow` 等)。
        var kind: String
        /// 指令字串 + 寫進 stdin 的位元組。
        var sent: Int
        /// stdout + stderr 的位元組。
        var received: Int
    }

    let shell: LocalShellHost
    private(set) var exchanges: [Exchange] = []
    /// 長駐追蹤通道上送出的請求行數(每行一輪)。
    private(set) var followRounds = 0
    /// 推給事件訂閱的事件行數。
    private(set) var pushedEvents = 0
    /// 主機檔案長駐通道上各種讀取(`hostFiles.theme` 等)的請求數與兩個方向的位元組(#203)。
    private(set) var hostFileRounds: [String: (count: Int, bytes: Int)] = [:]
    /// 長駐讀取還沒回應的請求種類(依序)。
    private var pendingHostFileKinds: [String] = []
    /// 各 pane 目前的 Agent 狀態(快照回應依它改)。
    private var statuses: [String: String]
    /// 快照裡另外加的 Agent(pane id → Claude session id),以 `w1:pB` 為樣本。
    private let extraAgents: [String: String]
    /// 收到主機資料的模擬時間(keepalive 估算用:間隔內有資料就跳過)。
    private(set) var inboundTimes: [Duration] = []
    private let clock: SimulatedClock?
    private var subscriptions: [(exchange: Int, continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation)] = []
    private var runningCommands = 0
    private var pendingFollowReplies = 0
    private var followBuffers: [Int: Data] = [:]

    init(shell: LocalShellHost, statuses: [String: String], extraAgents: [String: String] = [:], clock: SimulatedClock? = nil) {
        self.shell = shell
        self.statuses = statuses
        self.extraAgents = extraAgents
        self.clock = clock
    }

    private func noteInbound() async {
        guard let clock else { return }
        inboundTimes.append(await clock.elapsed)
    }

    /// 還在跑的一次性指令與還沒回應的追蹤請求。
    var inFlight: Int { runningCommands + pendingFollowReplies + pendingHostFileKinds.count }

    /// 有任何動靜就會變的數字(判斷被測物是否還在動)。
    var activity: Int { exchanges.count + followRounds + hostFileRounds.values.reduce(0) { $0 + $1.count } + exchanges.reduce(0) { $0 + $1.received } }

    func count(_ kind: String) -> Int { exchanges.filter { $0.kind == kind }.count }

    func setStatus(_ status: String, of paneID: String) {
        statuses[paneID] = status
    }

    /// 對每條開著的事件訂閱推一個 Agent 狀態事件(與 #159 錄到的形狀相同：事件名用點)。
    func pushStatusChanged(_ paneID: String, status: String) {
        let line = Data(#"{"event":"pane.agent_status_changed","data":{"agent":"claude","agent_status":"\#(status)","pane_id":"\#(paneID)","workspace_id":"w1"}}"#.utf8) + [0x0A]
        if !subscriptions.isEmpty { Task { await noteInbound() } }
        for subscription in subscriptions {
            exchanges[subscription.exchange].received += line.count
            pushedEvents += 1
            subscription.continuation.yield(.stdout(line))
        }
    }

    // MARK: - HostChannel

    func execute(_ command: String) async throws -> any ExecSession {
        let index = exchanges.count
        exchanges.append(Exchange(kind: Self.kind(of: command), sent: command.utf8.count, received: 0))
        let (output, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
        if command.hasSuffix(" remote-api-bridge") {
            return BridgeSession(output: output, continuation: continuation, host: self, exchange: index)
        }
        let isFollow = ["transcript.follow", "hostFiles.follow"].contains(exchanges[index].kind)
        let inner = try await shell.execute(command)
        if !isFollow { runningCommands += 1 }
        Task {
            do {
                for try await event in inner.output {
                    self.received(event, exchange: index, isFollow: isFollow)
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            self.ended(exchange: index, isFollow: isFollow)
        }
        return ShellSession(inner: inner, output: output, host: self, exchange: index, isFollow: isFollow)
    }

    func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        throw FakeHostError.unexpectedPTY(request)
    }

    // MARK: - herdr bridge

    fileprivate func answerBridge(
        _ request: Data, exchange index: Int, continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation
    ) {
        let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
        let method = object?["method"] as? String ?? "?"
        let params = object?["params"] as? [String: Any]
        exchanges[index].kind = method
        exchanges[index].sent += request.count
        let reply: Data = switch method {
        case "events.subscribe": Fixtures.data("events.subscribe.started.ndjson")
        case "session.snapshot": snapshot()
        case "pane.read": Fixtures.data(params?["format"] as? String == "ansi" ? "pane.read.ansi.no-suggestion.ndjson" : "pane.read.visible.ndjson")
        case "pane.report_metadata": Fixtures.data("pane.report-metadata.ndjson")
        default: Fixtures.data("error.invalid-request.ndjson")
        }
        exchanges[index].received += reply.count
        Task { await noteInbound() }
        continuation.yield(.stdout(reply))
        if method == "events.subscribe" {
            subscriptions.append((index, continuation))
        } else {
            continuation.yield(.exit(code: 0))
            continuation.finish()
        }
    }

    fileprivate func closeBridge(exchange index: Int, continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation) {
        subscriptions.removeAll { $0.exchange == index }
        continuation.finish()
    }

    private func snapshot() -> Data {
        let statuses = statuses
        let extraAgents = extraAgents
        return Fixtures.modifiedLine("session.snapshot.ndjson") { response in
            for (paneID, sessionID) in extraAgents.sorted(by: { $0.key < $1.key }) {
                SnapshotEdit.addAgent(copying: "w1:pB", as: paneID, sessionID: sessionID, in: &response)
            }
            for (paneID, status) in statuses {
                SnapshotEdit.agent(paneID, in: &response) { $0["agent_status"] = status }
            }
        }
    }

    // MARK: - 對話紀錄指令(本機 shell)

    fileprivate func sent(_ data: Data, exchange index: Int, isFollow: Bool) {
        exchanges[index].sent += data.count
        guard isFollow else { return }
        if exchanges[index].kind == "hostFiles.follow" {
            for line in data.split(separator: 0x0A) {
                let paths = String(decoding: line, as: UTF8.self).split(separator: " ").enumerated().filter { $0.offset.isMultiple(of: 2) }.map { HostPath(String($0.element)) }
                let kind = Self.hostFileKind(paths)
                hostFileRounds[kind, default: (0, 0)].count += 1
                hostFileRounds[kind, default: (0, 0)].bytes += line.count + 1
                pendingHostFileKinds.append(kind)
            }
            return
        }
        let lines = data.filter { $0 == 0x0A }.count
        followRounds += lines
        pendingFollowReplies += lines
    }

    private func received(_ event: ExecOutput, exchange index: Int, isFollow: Bool) {
        switch event {
        case .stdout(let data):
            Task { await noteInbound() }
            exchanges[index].received += data.count
            if isFollow { countFollowReplies(in: data, exchange: index) }
        case .stderr(let data):
            exchanges[index].received += data.count
        case .exit:
            break
        }
    }

    /// 追蹤腳本的每則回應以 `TranscriptFollowProtocol.endsReply` 的一行結束(紀錄行以數字開頭);
    /// 主機檔案的每則回應以 `HostFileScript.takeFollowReply` 切出。
    private func countFollowReplies(in data: Data, exchange index: Int) {
        var buffer = followBuffers[index, default: Data()] + data
        if exchanges[index].kind == "hostFiles.follow" {
            while !pendingHostFileKinds.isEmpty {
                let before = buffer.count
                guard (try? HostFileScript.takeFollowReply(from: &buffer)) != nil else { break }
                hostFileRounds[pendingHostFileKinds.removeFirst(), default: (0, 0)].bytes += before - buffer.count
            }
            followBuffers[index] = buffer
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(...newline)
            if TranscriptFollowProtocol.endsReply(line) {
                pendingFollowReplies = max(0, pendingFollowReplies - 1)
            }
        }
        followBuffers[index] = buffer
    }

    private func ended(exchange index: Int, isFollow: Bool) {
        if exchanges[index].kind == "hostFiles.follow" {
            pendingHostFileKinds = []
        } else if isFollow {
            pendingFollowReplies = 0
        } else {
            runningCommands -= 1
        }
    }

    private static func hostFileKind(_ paths: [HostPath]) -> String {
        if paths.contains(HostThemeHost.configPath) { return "hostFiles.theme" }
        if paths.contains(ClaudePlanUsageHost.usagePath) { return "hostFiles.usage" }
        return "hostFiles.notes"
    }

    private static func kind(of command: String) -> String {
        if command.hasSuffix(" remote-api-bridge") { return "herdr" }
        if command.hasPrefix(TranscriptCommand.followInvocation) { return "transcript.follow" }
        if command.hasPrefix(HostFileScript.followInvocation) { return "hostFiles.follow" }
        if let request = HostFileRequest(command: command) {
            switch request {
            case .readIfChanged(let paths, _), .read(let paths):
                return hostFileKind(paths)
            case .newest: return "hostFiles.notes.locate"
            case .apply: return "hostFiles.apply"
            }
        }
        let scripts: [(String, String)] = [
            ("transcript.previews", TranscriptCommand.previewsScript),
            ("transcript.window", TranscriptCommand.windowScript),
            ("transcript.catchUp", TranscriptCommand.catchUpScript),
            ("transcript.tail", TranscriptCommand.tailScript),
            ("transcript.locate", TranscriptCommand.claudeLocateScript),
        ]
        return scripts.first { command.hasPrefix(TranscriptCommand.command($0.1, arguments: [])) }?.0 ?? "transcript.other"
    }
}

private struct BridgeSession: ExecSession {
    let output: AsyncThrowingStream<ExecOutput, any Error>
    let continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation
    let host: MeteredSSHHost
    let exchange: Int

    func write(_ data: Data) async throws {
        await host.answerBridge(data, exchange: exchange, continuation: continuation)
    }

    func closeStdin() async {}

    func close() async {
        await host.closeBridge(exchange: exchange, continuation: continuation)
    }
}

private struct ShellSession: ExecSession {
    let inner: any ExecSession
    let output: AsyncThrowingStream<ExecOutput, any Error>
    let host: MeteredSSHHost
    let exchange: Int
    let isFollow: Bool

    func write(_ data: Data) async throws {
        await host.sent(data, exchange: exchange, isFollow: isFollow)
        try await inner.write(data)
    }

    func closeStdin() async { await inner.closeStdin() }

    func close() async { await inner.close() }
}

#endif
