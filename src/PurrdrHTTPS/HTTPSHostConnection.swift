import Foundation
import PurrdrCore
import Synchronization

/// HTTPS 連線方式的主機連線(ADR-0010):單一 WSS 連到主機服務，帶裝置權杖;herdr 請求換成主機服務協定的窄 API。
///
/// - 第一個操作時才撥號並握手(`hello`);斷線後下一個操作重新撥號，進行中的請求不重送。
/// - 心跳(`heartbeat`)逾時視同斷線：進行中的請求與事件串流以 `connectionLost` 結束。
/// - 權杖被拒(無效、已撤銷)後，同一個權杖不再撥號，直到存了新的權杖(重新配對):不會無限重連。
/// - 型別化操作直接對應主機服務訊息(`HTTPSTypedOperations.swift`);協定沒有對應的操作丟 `HostServiceError.unsupported`。
/// - Pane 終端機是同一條 WSS 上的串流(`openPaneTerminal`)。
public actor HTTPSHostConnection: HostConnection {
    private let address: HostServiceAddress
    private let deviceToken: @Sendable () throws -> String?
    private let transport: any WebSocketConnecting
    /// 流量計量(#353):WebSocket 收送的訊息位元組;建立後才接上也算。
    private let trafficSink: TrafficSink
    private let appVersion: String?
    private let heartbeat: HostServiceHeartbeat
    private let quickHeartbeat: HostServiceHeartbeat
    /// 要求快速偵測斷線的次數(聊天畫面可見)。
    private var quickDetectionRequests = 0
    private var currentHeartbeat: HostServiceHeartbeat { quickDetectionRequests > 0 ? quickHeartbeat : heartbeat }
    private let sleep: Sleep
    private var session: HostServiceSession?
    private var welcome: HostServiceProtocol.Welcome?
    private var connecting: Task<HostServiceSession, any Error>?
    private var rejection: RejectedToken?
    /// 連線診斷(#689):撥號、握手、結束原因與壽命。
    private let diagnostics: HTTPSConnectionDiagnostics?
    /// 耗時記錄的出口(建立後才接上也算)。
    let timingSink = TimingSinkHolder()
    private var dialCount = 0
    /// 追蹤中的對話紀錄(路徑 → 追蹤)。見 `HTTPSTranscripts.swift`。
    var transcriptFollows: [String: TranscriptFollow] = [:]
    /// 追蹤串流(`followTranscript`,路徑 → 串流)。同一個路徑只有一個。
    var transcriptStreams: [String: TranscriptStream] = [:]
    /// 列表預覽定位到的對話紀錄(主機服務只認得這條連線定位過的;連線結束時清空)。
    var previewLocations: [TranscriptLocation: PreviewLocation] = [:]

    /// 被拒的權杖與原因(同一個權杖不再撥號)。
    private struct RejectedToken {
        var deviceToken: String
        var error: HostServiceError
    }

    /// - Parameters:
    ///   - deviceToken: 撥號時才讀(Keychain);`nil` 表示還沒配對。
    ///   - heartbeat: WSS 心跳的間隔與逾時(測試用短的)。
    ///   - quickHeartbeat: 快速偵測斷線(聊天畫面可見)時的心跳。
    ///   - sleep: 期限與心跳計時用(測試注入)。
    public init(
        address: HostServiceAddress, deviceToken: @escaping @Sendable () throws -> String?,
        transport: any WebSocketConnecting = URLSessionHostServiceTransport(), appVersion: String? = nil,
        heartbeat: HostServiceHeartbeat = .standard, quickHeartbeat: HostServiceHeartbeat = .quick, sleep: @escaping Sleep = Sleeping.task,
        traffic: TrafficRecording? = nil, diagnostics: HTTPSConnectionDiagnostics? = nil
    ) {
        self.diagnostics = diagnostics
        trafficSink = TrafficSink(traffic)
        self.address = address
        self.deviceToken = deviceToken
        self.transport = MeteredWebSocketTransport(base: transport, sink: trafficSink)
        self.appVersion = appVersion
        self.heartbeat = heartbeat
        self.quickHeartbeat = quickHeartbeat
        self.sleep = sleep
    }

    /// 接上關鍵請求的耗時記錄(#689);沒接時不記。
    public nonisolated func attachTimings(_ sink: OperationTimingSink?) {
        timingSink.attach(sink)
    }

    /// 接上流量計量(#353)。
    public nonisolated func attachTraffic(_ recording: TrafficRecording?) {
        trafficSink.attach(recording)
    }

    /// 握手得到的主機服務與 herdr 伺服器資訊(連線測試顯示用)。
    public func hostServiceInfo() async throws -> HostServiceProtocol.Welcome {
        _ = try await liveSession()
        guard let welcome else { throw HostServiceError.unexpectedResponse }
        return welcome
    }

    /// 握手時主機服務回報的唯讀。
    public func isReadOnlyDevice() async throws -> Bool {
        try await hostServiceInfo().readOnly
    }

    public func hostServiceVersion() async throws -> String? {
        try await hostServiceInfo().hostServiceVersion
    }

    /// 主機服務 0.7.0 起在送出前比對(`HostServiceFeature.sendExpectations`);更舊的不認得這些欄位，不帶。
    /// 連不上時回 `false`:接著的送出自己會回報連線錯誤。
    public func checksSendExpectations() async -> Bool {
        HostServiceFeature.sendExpectations.isAvailable(onHostServiceVersion: (try? await hostServiceVersion()) ?? nil)
    }

    /// 主機服務版本不足時丟 `HostServiceError.hostServiceUpdateRequired`;門檻見 `HostServiceFeature.minimumVersion`。
    /// 一律在送出前、`withDeadline` 外呼叫(撥號與握手各有自己的期限)。
    public func requireHostService(_ feature: HostServiceFeature) async throws {
        let installed = try await hostServiceVersion()
        guard feature.isAvailable(onHostServiceVersion: installed) else {
            throw HostServiceError.hostServiceUpdateRequired(feature, installedVersion: installed)
        }
    }

    // MARK: - Agent 事件串流

    /// 事件訂閱(`events.subscribe`):主機接受後第一項是 `.subscriptionStarted`,之後是事件;
    /// 主機端結束串流(`events_lost` 是 `HerdrError.herdr`)或連線結束(含心跳逾時)時串流跟著結束，上層據此重連對帳。
    /// 呼叫端不再讀時通知主機服務關掉那條串流，連線留給其他操作。
    public func subscribeToEvents(_ subscriptions: [PurrdrCore.EventSubscription]) async throws -> AsyncThrowingStream<HerdrEvent, any Error> {
        let wire = subscriptions.map { HostServiceProtocol.EventSubscription(event: $0.type.rawValue, paneId: $0.paneID) }
        let subscribed = try await withDeadline(HostCommandDeadline.standard) {
            try await self.subscribeEvents(wire)
        }
        let (session, streamID) = (subscribed.session, subscribed.streamID)
        let (events, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
        continuation.yield(.subscriptionStarted)
        let forwarding = Task {
            do {
                for try await message in subscribed.messages {
                    switch message {
                    case .subscribedEvent(let event):
                        continuation.yield(.event(name: event.event, paneID: event.paneId))
                    case .eventsEnded(let ended):
                        if let code = ended.code {
                            throw Self.error(for: .init(code: code, message: ended.message ?? "", herdrCode: ended.herdrCode))
                        }
                    default:
                        continue
                    }
                }
                continuation.finish()
            } catch {
                self.noteEnding(error, of: session)
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            forwarding.cancel()
            Task { await self.unsubscribeEvents(streamID, on: session) }
        }
        return events
    }

    /// 主機接受的事件串流。
    private struct EventSubscription: Sendable {
        var session: HostServiceSession
        var streamID: String
        var messages: HostServiceSession.Messages
    }

    private func subscribeEvents(_ subscriptions: [HostServiceProtocol.EventSubscription]) async throws -> EventSubscription {
        let session = try await liveSession()
        let streamID = await session.makeStreamID()
        let messages = await session.openStream(streamID)
        do {
            let reply = try await send(on: session) { .eventsSubscribe(.init(requestId: $0, streamId: streamID, subscriptions: subscriptions)) }
            guard case .eventsSubscribeResult = reply else { throw HostServiceError.unexpectedResponse }
        } catch {
            await session.closeStream(streamID)
            // 取消時請求可能已送達、主機已開了串流：不等待地請它關掉。
            if error is CancellationError {
                Task { _ = try? await session.request { .eventsUnsubscribe(.init(requestId: $0, streamId: streamID)) } }
            }
            throw error
        }
        return EventSubscription(session: session, streamID: streamID, messages: messages)
    }

    /// 呼叫端不再讀：串流還開著就請主機服務關掉(主機端已結束或連線已斷就不必)。
    private func unsubscribeEvents(_ streamID: String, on session: HostServiceSession) async {
        guard await session.closeStream(streamID) else { return }
        _ = try? await session.request { .eventsUnsubscribe(.init(requestId: $0, streamId: streamID)) }
    }

    // MARK: - 對話紀錄

    /// 請主機服務停止追蹤這個對話紀錄。
    public func stopFollowingTranscript(path: String) async {
        transcriptStreams.removeValue(forKey: path)?.continuation.finish()
        guard let follow = transcriptFollows.removeValue(forKey: path) else { return }
        await stopFollowing(follow)
    }

    // MARK: - Pane 終端機

    /// 主機服務以子行程執行 `herdr terminal session control`(唯讀裝置是 observe)並轉接畫面更新(#61、ADR-0005)。
    /// 與 Agent 列表共用同一條 WSS;WSS 斷線時以 `.disconnected` 結束。開啟有期限(含撥號與握手)。
    public func openPaneTerminal(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> PaneTerminalConnection {
        let opened = try await withDeadline(HostCommandDeadline.standard) {
            try await self.openTerminalStream(target: target, columns: columns, rows: rows, takeover: takeover)
        }
        let (events, continuation) = AsyncStream<PaneTerminalEvent>.makeStream()
        let relay = Task {
            do {
                for try await message in opened.messages {
                    guard let event = PaneTerminalStreamEvent.make(message) else { continue }
                    continuation.yield(event)
                    if case .frame = event { continue }
                    continuation.finish()
                    return
                }
            } catch {}
            // 沒有 pane.terminal.closed 就結束(連線結束時串流以錯誤結束):WSS 斷了，可以重新連線。
            continuation.yield(.disconnected)
            continuation.finish()
        }
        let transport = HostServiceTerminalTransport(session: opened.session, streamID: opened.result.streamId)
        continuation.onTermination = { termination in
            relay.cancel()
            // 呼叫端不再讀：請主機結束 terminal 子行程，不留到 WSS 斷線。
            if case .cancelled = termination { Task { await transport.release() } }
        }
        return PaneTerminalConnection(events: events, transport: transport, isViewOnly: opened.result.readOnly)
    }

    /// 主機開好的 Pane 終端機串流。
    private struct OpenedTerminal: Sendable {
        var session: HostServiceSession
        var result: HostServiceProtocol.PaneTerminalOpenResult
        var messages: HostServiceSession.Messages
    }

    private func openTerminalStream(target: String, columns: Int, rows: Int, takeover: Bool) async throws -> OpenedTerminal {
        let session = try await liveSession()
        let opened: HostServiceSession.StreamReply
        do {
            opened = try await session.requestStream(
                { .paneTerminalOpen(.init(requestId: $0, target: target, columns: columns, rows: rows, takeover: takeover)) },
                closing: { .paneTerminalClose(.init(streamId: $0)) })
        } catch {
            noteEnding(error, of: session)
            throw error
        }
        switch opened.reply {
        case .paneTerminalOpenResult(let result): return OpenedTerminal(session: session, result: result, messages: opened.messages)
        case .errorMessage(let error): throw Self.error(for: error)
        default: throw HostServiceError.unexpectedResponse
        }
    }

    public func disconnect() async {
        let current = session
        session = nil
        welcome = nil
        // 主機服務在連線結束時停止這條連線的所有追蹤。
        transcriptFollows = [:]
        previewLocations = [:]
        await current?.close()
    }

    // MARK: - 連線

    /// 送出請求;權杖被拒時記下來。
    func send(_ make: @Sendable (String) -> HostServiceProtocol.ClientMessage) async throws -> HostServiceProtocol.ServerMessage {
        try await send(on: liveSession(), make)
    }

    /// 送出請求，主機服務的錯誤訊息原樣回傳(`.errorMessage`),由呼叫端依操作對應成自己的錯誤。
    func sendKeepingErrors(_ make: @Sendable (String) -> HostServiceProtocol.ClientMessage) async throws -> HostServiceProtocol.ServerMessage {
        let session = try await liveSession()
        do {
            return try await session.request(make)
        } catch {
            noteEnding(error, of: session)
            throw error
        }
    }

    /// 在這條連線送出請求(呼叫端先在連線上準備好，例如開好串流)。
    /// - Parameter herdrMethod: 換成這個訊息的 herdr method(錯誤依 method 解讀，見 `error(for:herdrMethod:)`)。
    func send(
        on session: HostServiceSession, _ make: @Sendable (String) -> HostServiceProtocol.ClientMessage, herdrMethod: String? = nil
    ) async throws -> HostServiceProtocol.ServerMessage {
        let reply: HostServiceProtocol.ServerMessage
        do {
            reply = try await session.request(make)
        } catch {
            noteEnding(error, of: session)
            throw error
        }
        if case .errorMessage(let error) = reply { throw Self.error(for: error, herdrMethod: herdrMethod) }
        return reply
    }

    /// `workspace.create` 的 `invalid_message` 是資料夾不存在或不是絕對路徑(協定沒有專屬錯誤碼),換成 herdr 錯誤 `folder_not_found`。
    static func error(for message: HostServiceProtocol.ErrorMessage, herdrMethod: String?) -> any Error {
        // 0.12.0 起資料夾不存在回 `directory_not_found`;更舊的主機服務回 `invalid_message`。
        if herdrMethod == HerdrMethod.workspaceCreate.rawValue, message.code == .invalidMessage || message.code == .directoryNotFound {
            return HerdrError.herdr(code: "folder_not_found", message: message.message)
        }
        return error(for: message)
    }

    /// 心跳改用短間隔(聊天畫面可見時)。
    public func beginQuickDisconnectDetection() async {
        quickDetectionRequests += 1
        await session?.setHeartbeat(currentHeartbeat)
    }

    public func endQuickDisconnectDetection() async {
        quickDetectionRequests = max(0, quickDetectionRequests - 1)
        await session?.setHeartbeat(currentHeartbeat)
    }

    func liveSession() async throws -> HostServiceSession {
        if let session, await session.isOpen { return session }
        if let connecting { return try await connecting.value }
        guard let token = try deviceToken() else { throw HostServiceError.notPaired }
        if let rejection, rejection.deviceToken == token { throw rejection.error }
        let opening = Task { try await self.open(deviceToken: token) }
        connecting = opening
        defer { connecting = nil }
        do {
            let opened = try await opening.value
            session = opened
            // 撥號期間開始或結束了快速偵測。
            await opened.setHeartbeat(currentHeartbeat)
            return opened
        } catch let error as HostServiceError where error.requiresPairing {
            rejection = RejectedToken(deviceToken: token, error: error)
            throw error
        }
    }

    /// 撥號並握手。握手有自己的期限，卡住的主機服務不會讓之後的操作一直等。
    private func open(deviceToken token: String) async throws -> HostServiceSession {
        dialCount += 1
        let dial = dialCount
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let opened = try await dialAndHandshake(deviceToken: token)
            let connectedAt = clock.now
            diagnostics?(.connected(dial: dial))
            if let diagnostics {
                await opened.observeEnd { reason in
                    diagnostics(.dropped(dial: dial, reason: reason, lifetime: clock.now - connectedAt))
                }
            }
            return opened
        } catch {
            diagnostics?(.dialFailed(dial: dial, error: HTTPSConnectionEvent.kind(of: error), elapsed: clock.now - start))
            throw error
        }
    }

    private func dialAndHandshake(deviceToken token: String) async throws -> HostServiceSession {
        let socket = try await transport.connect(to: address.webSocketURL, bearerToken: token)
        let opened = HostServiceSession(socket: socket, deviceToken: token, heartbeat: currentHeartbeat, sleep: sleep)
        await opened.start()
        let appVersion = appVersion
        let reply: HostServiceProtocol.ServerMessage
        do {
            reply = try await withDeadline(HostCommandDeadline.standard) {
                try await opened.request { .hello(.init(requestId: $0, protocolVersion: HostServiceProtocol.version, appVersion: appVersion)) }
            }
        } catch HerdrError.deadlineExceeded {
            await opened.close()
            throw HostServiceError.unreachable
        } catch {
            await opened.close()
            throw error
        }
        switch reply {
        case .welcome(let welcome):
            self.welcome = welcome
            return opened
        case .errorMessage(let error):
            await opened.close()
            throw Self.error(for: error)
        default:
            await opened.close()
            throw HostServiceError.unexpectedResponse
        }
    }

    /// 連線結束：權杖被拒就記下(之後同一個權杖不再撥號)。
    private func noteEnding(_ error: any Error, of ended: HostServiceSession) {
        if let rejected = error as? HostServiceError, rejected.requiresPairing {
            rejection = RejectedToken(deviceToken: ended.deviceToken, error: rejected)
        }
        if session === ended, !(error is CancellationError) { session = nil }
    }

    /// 主機服務的錯誤訊息換成 app 的錯誤。herdr 自己的錯誤保留 herdr 的碼與原文。
    static func error(for message: HostServiceProtocol.ErrorMessage) -> any Error {
        switch message.code {
        case .deviceTokenInvalid: HostServiceError.deviceTokenInvalid
        case .deviceTokenRevoked: HostServiceError.deviceTokenRevoked
        case .protocolVersionUnsupported: HostServiceError.protocolVersionUnsupported(supported: message.supportedProtocolVersions ?? [])
        case .herdrUnavailable: HostServiceError.herdrUnavailable
        case .herdrCapabilityMissing: HostServiceError.herdrCapabilityMissing
        case .herdrError: HerdrError.herdr(code: message.herdrCode ?? "herdr_error", message: message.message)
        case .readOnlyDevice: HostServiceError.readOnlyDevice
        case .pairingCodeInvalid: HostServiceError.pairingCodeInvalid
        case .pairingCodeExpired: HostServiceError.pairingCodeExpired
        case .transcriptAbsent: TranscriptReadError.absent
        case .transcriptUnreadable: TranscriptReadError.unreadable
        case .transcriptAmbiguous: TranscriptReadError.ambiguous
        case .transcriptCompressed: TranscriptReadError.compressed
        case .transcriptNotAllowed: TranscriptReadError.invalidReference
        case .transcriptUnsupported: HostServiceError.unsupported("transcript")
        case .fileChanged: HostFileFetchError.changed
        case .uploadTooLarge: HostUploadError.tooLarge
        case .deviceUnknown: HostServiceError.deviceUnknown
        // 只回覆 `push.*`,由 `HostServicePushPluginInstaller` 依操作直接對應。
        case .pushPluginFailed, .pushNotPaired, .pushSendFailed, .invalidMessage, .handshakeRequired, .internalError: HostServiceError.unexpectedResponse
        case .hostServiceNotInstalled: HostServiceManagementError.notInstalledCopy
        case .updateInProgress: HostServiceManagementError.updateInProgress
        case .updateFailed: HostServiceManagementError.updateFailed(message.message)
        case .paneChanged: HostServiceError.paneChanged
        // 變更頁(#310):Agent 已換資料夾或結束、工作目錄不在 git repo 裡。
        case .cwdNotAllowed: GitChangesError.cwdNotAllowed
        case .notGitRepository: GitChangesError.notGitRepository
        // Send When Done 佇列(#305)。
        case .queueFull: HostServiceError.queueFull
        case .queueItemUnknown: HostServiceError.queueItemUnknown
        // 用量與資料夾瀏覽(0.12.0):`HTTPSHostUsage.swift` 依操作直接對應;其他操作收到就是看不懂。
        case .codexNotFound, .codexNotSignedIn, .codexFailed, .claudeNotFound, .claudeSettingsNotJson, .hostWriteFailed,
            .directoryNotFound, .directoryNotAllowed, .directoryUnreadable: HostServiceError.unexpectedResponse
        }
    }

    /// 期限到丟 `HerdrError.deadlineExceeded`;外層取消丟 `CancellationError`。
    /// 操作在期限到或取消之後仍拿到結果時回傳結果：主機可能已為它開了串流，交給呼叫端收尾而不是丟掉。
    func withDeadline<Value: Sendable>(
        _ deadline: Duration, _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let outcome = await withTaskGroup(of: DeadlineRace<Value>.self) { group -> Result<Value, any Error> in
            group.addTask {
                do {
                    return .finished(.success(try await operation()))
                } catch {
                    return .finished(.failure(error))
                }
            }
            group.addTask { [sleep] in
                try? await sleep(deadline)
                return .timerEnded
            }
            let first = await group.next()
            group.cancelAll()
            if case .finished(let result) = first { return result }
            while let race = await group.next() {
                if case .finished(.success(let value)) = race { return .success(value) }
            }
            return .failure(Task.isCancelled ? CancellationError() : HerdrError.deadlineExceeded)
        }
        return try outcome.get()
    }
}

/// `withDeadline` 裡先結束的一方。
private enum DeadlineRace<Value: Sendable>: Sendable {
    case finished(Result<Value, any Error>)
    /// 期限到或外層取消。
    case timerEnded
}

/// Pane 終端機的輸入以主機服務協定送出;不等回應(主機服務不回應輸入)。
struct HostServiceTerminalTransport: PaneTerminalTransport {
    let session: HostServiceSession
    let streamID: String

    func send(_ input: TerminalInput) async throws {
        let message: HostServiceProtocol.ClientMessage
        switch input {
        case .bytes(let data):
            message = .paneTerminalInput(.init(streamId: streamID, bytes: data.base64EncodedString()))
        case .resize(let columns, let rows):
            message = .paneTerminalResize(.init(streamId: streamID, columns: columns, rows: rows))
        case .scroll(let direction, let lines, let column, let row, let source):
            // wheel 不帶 source(協定預設),舊版主機服務收到的訊息不變。
            message = .paneTerminalScroll(.init(
                streamId: streamID, direction: direction == .up ? .up : .down, lines: lines, column: column, row: row,
                source: source == .pageKey ? .pageKey : nil))
        case .release:
            return await release()
        }
        try await session.post(message)
    }

    /// control 等同 release;主機服務結束子行程後送 `pane.terminal.closed`。
    func release() async {
        try? await session.post(.paneTerminalClose(.init(streamId: streamID)))
    }
}

/// 主機服務的串流訊息換成 Pane 終端機事件(與 SSH 路線解出的相同)。
enum PaneTerminalStreamEvent {
    static func make(_ message: HostServiceProtocol.ServerMessage) -> PaneTerminalEvent? {
        switch message {
        case .paneTerminalFrame(let frame):
            guard let bytes = Data(base64Encoded: frame.bytes), frame.seq > 0 else { return nil }
            return .frame(TerminalFrame(seq: UInt64(frame.seq), columns: frame.width, rows: frame.height, full: frame.full, bytes: bytes))
        case .paneTerminalClosed(let closed):
            switch closed.ending {
            case .closed: return .closed(TerminalCloseReason(herdr: closed.reason))
            case .disconnected: return .disconnected
            case .failed: return .failed(exitCode: Int32(clamping: closed.exitCode ?? 1), message: closed.message ?? "")
            }
        default:
            return nil
        }
    }
}

/// 可事後接上的耗時出口(閉包放在 class 的 `let`,見 `TrafficSink` 的說明)。
final class TimingSinkHolder: Sendable {
    private final class Box: Sendable {
        let sink: OperationTimingSink
        init(_ sink: @escaping OperationTimingSink) { self.sink = sink }
    }

    private let box = Mutex<Box?>(nil)

    func attach(_ sink: OperationTimingSink?) {
        let new = sink.map(Box.init)
        box.withLock { $0 = new }
    }

    var current: OperationTimingSink? { box.withLock { $0 }?.sink }
}
