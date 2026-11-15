import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// SSH 連到哪裡、以誰登入。
public struct SSHEndpoint: Sendable, Hashable, Codable {
    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }
}

/// SSH 各階段的期限(行為規格 §7.2:每一步都要有明確期限，不依賴函式庫預設)。
public struct SSHTimeouts: Sendable, Equatable {
    /// TCP 連線。
    public var connect: TimeAmount
    /// SSH 握手加上認證。主機接受 TCP 卻永遠不說 SSH 時靠它結束。
    public var handshake: TimeAmount
    /// 開 channel 與等 exec／pty-req 的回覆。
    public var channelOpen: TimeAmount
    /// 連線閒置時多久送一次 keepalive(`nil` 不送)。iOS 沒有 TCP 層的提早發現，半開連線靠它在使用者動作前就被丟棄。
    public var keepaliveInterval: TimeAmount?
    /// keepalive 送出後等主機回應的期限;到了視為半開連線，整條丟棄(下一個指令重撥)。
    public var keepaliveReply: TimeAmount

    public init(
        connect: TimeAmount = .seconds(10), handshake: TimeAmount = .seconds(15), channelOpen: TimeAmount = .seconds(20),
        keepaliveInterval: TimeAmount? = .seconds(20), keepaliveReply: TimeAmount = .seconds(15)
    ) {
        self.connect = connect
        self.handshake = handshake
        self.channelOpen = channelOpen
        self.keepaliveInterval = keepaliveInterval
        self.keepaliveReply = keepaliveReply
    }
}

/// SSH 連線層的錯誤。函式庫的內部錯誤字串不給使用者看(行為規格 §7.6),一律換成這裡的情況。
public enum SSHConnectionError: Error, Equatable, Sendable {
    /// 沒有 pin:主機出示了這個指紋，等使用者確認才登入(TOFU)。
    case hostKeyUnverified(presented: HostKeyFingerprint)
    /// 主機出示的 key 與已存的不同。可能重灌過，也可能有人攔截連線(行為規格 §8.2)。
    case hostKeyChanged(presented: HostKeyFingerprint, pinned: HostKeyFingerprint)
    /// 主機拒絕登入(Tailscale SSH 不放行這個使用者)。
    case authenticationFailed
    /// 主機拒絕連線:埠不對，或 SSH 沒開。
    case connectionRefused
    /// 找不到這個主機名稱。
    case hostNotFound
    /// 連線或握手逾時:主機睡著、不在 tailnet,或手機不在 tailnet。
    case timedOut
    /// 其他無法連上的情況。
    case unreachable
    /// 指令執行到一半連線斷了。主機可能已經執行，所以**不會自動重送**(行為規格 §7.3)。
    case connectionLost
    /// 連線健康，但主機拒絕開新的 channel 或拒絕 exec／pty 請求(例如 `MaxSessions`)。
    case channelRejected
}

/// 真 SSH 的主機通道(ADR-0003:swift-nio-ssh)。
///
/// - 每台主機一條長駐連線，所有指令共用;第一個指令才撥號，同時的撥號合併成一個(行為規格 §7.1)。
/// - 失敗的連線不快取;斷掉的連線在下一個指令前丟棄重撥。
/// - 連線層失敗的指令不自動重送(行為規格 §7.3)。
/// - 沒有 pin 時不登入，回報主機出示的指紋讓使用者確認(TOFU,行為規格 §8.2)。
public actor SSHHostChannel: HostChannel {
    public nonisolated let endpoint: SSHEndpoint
    private let hostKeyPin: HostKeyFingerprint?
    private let timeouts: SSHTimeouts
    private let group: any EventLoopGroup

    private var connection: SSHConnection?
    private var dial: (id: Int, task: Task<SSHConnection, any Error>)?
    private var dialCount = 0

    public init(
        endpoint: SSHEndpoint, hostKeyPin: HostKeyFingerprint?, timeouts: SSHTimeouts = SSHTimeouts(),
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.endpoint = endpoint
        self.hostKeyPin = hostKeyPin
        self.timeouts = timeouts
        group = eventLoopGroup
    }

    public func execute(_ command: String) async throws -> any ExecSession {
        let connection = try await connected()
        do {
            let (channel, events) = try await connection.openSession([.exec(command)], timeout: timeouts.channelOpen)
            return SSHExecSession(channel: channel, events: events)
        } catch {
            throw drop(connection, after: error)
        }
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        let connection = try await connected()
        let start: SessionRequest = request.command.map { .exec($0) } ?? .shell
        do {
            let (channel, events) = try await connection.openSession([.pty(request), start], timeout: timeouts.channelOpen)
            return SSHPTYSession(channel: channel, events: events)
        } catch {
            throw drop(connection, after: error)
        }
    }

    /// 關掉連線(編輯／刪除主機、信任新 key、app 結束時)。進行中的撥號完成後也會自行關閉。
    public func disconnect() async {
        dial = nil
        let connection = connection
        self.connection = nil
        await connection?.close()
    }

    // MARK: - 連線

    private func connected() async throws -> SSHConnection {
        if let connection {
            if connection.isActive { return connection }
            self.connection = nil
        }
        if let dial { return try await dial.task.value }

        dialCount += 1
        let id = dialCount
        let task = Task { [endpoint, hostKeyPin, timeouts, group] in
            try await SSHConnection.connect(to: endpoint, hostKeyPin: hostKeyPin, timeouts: timeouts, group: group)
        }
        dial = (id, task)
        do {
            let connection = try await task.value
            guard dial?.id == id else {
                // 撥號期間被 disconnect():不要留下沒人管的連線。
                await connection.close()
                throw SSHConnectionError.connectionLost
            }
            dial = nil
            self.connection = connection
            return connection
        } catch {
            if dial?.id == id { dial = nil }
            throw error
        }
    }

    /// 開 channel 失敗時：連線本身斷了才丟棄(下一個指令重撥);連線健康只讓這個請求失敗(行為規格 §7.3)。
    private func drop(_ failed: SSHConnection, after error: any Error) -> any Error {
        let isActive = failed.isActive
        if !isActive, connection === failed { connection = nil }
        if error as? SSHConnectionError == .timedOut {
            // 期限到被視為半開 socket 的證據：整條連線丟棄(行為規格 §7.2)。
            if connection === failed { connection = nil }
            Task { await failed.close() }
            return SSHConnectionError.timedOut
        }
        if let error = error as? SSHConnectionError { return error }
        return isActive ? SSHConnectionError.channelRejected : SSHConnectionError.connectionLost
    }
}

// MARK: - 一條 SSH 連線

/// 開 session channel 時依序送出的請求。
enum SessionRequest: Sendable {
    case exec(String)
    case shell
    case pty(PTYRequest)
}

/// session channel 往上送的事件。
enum SessionEvent: Sendable {
    case stdout(Data)
    case stderr(Data)
    case exitStatus(Int32)
    case exitSignal(String)
    /// channel 關閉。
    case closed
}

final class SSHConnection: Sendable {
    let channel: any Channel

    private init(channel: any Channel) {
        self.channel = channel
    }

    var isActive: Bool { channel.isActive }

    static func connect(
        to endpoint: SSHEndpoint, hostKeyPin: HostKeyFingerprint?, timeouts: SSHTimeouts, group: any EventLoopGroup
    ) async throws -> SSHConnection {
        let eventLoop = group.next()
        let authenticated = eventLoop.makePromise(of: Void.self)
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(timeouts.connect)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let configuration = SSHClientConfiguration(
                        userAuthDelegate: NoneAuthentication(username: endpoint.username),
                        serverAuthDelegate: HostKeyVerifier(pin: hostKeyPin))
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(role: .client(configuration), allocator: channel.allocator, inboundChildChannelInitializer: nil))
                    try channel.pipeline.syncOperations.addHandler(HandshakeHandler(authenticated: authenticated))
                }
            }

        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        } catch {
            authenticated.fail(error)
            throw Self.connectFailure(error)
        }
        let deadline = eventLoop.scheduleTask(in: timeouts.handshake) {
            authenticated.fail(SSHConnectionError.timedOut)
        }
        do {
            try await authenticated.futureResult.get()
            deadline.cancel()
            if let interval = timeouts.keepaliveInterval {
                startKeepalive(on: channel, every: interval, replyWithin: timeouts.keepaliveReply)
            }
            return SSHConnection(channel: channel)
        } catch {
            // 握手或認證失敗時一定要關 TCP,否則每次重試留下一個未認證連線(行為規格 §7.1)。
            deadline.cancel()
            try? await channel.close()
            throw error as? SSHConnectionError ?? .connectionLost
        }
    }

    func openSession(_ requests: [SessionRequest], timeout: TimeAmount) async throws
        -> (any Channel, AsyncStream<SessionEvent>)
    {
        let (events, continuation) = AsyncStream<SessionEvent>.makeStream()
        let channel = self.channel
        let started = channel.eventLoop.makePromise(of: (any Channel).self)
        let deadline = channel.eventLoop.scheduleTask(in: timeout) {
            started.fail(SSHConnectionError.timedOut)
        }
        channel.eventLoop.execute {
            guard channel.isActive else {
                started.fail(SSHConnectionError.connectionLost)
                return
            }
            do {
                let handler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let created = channel.eventLoop.makePromise(of: (any Channel).self)
                handler.createChannel(created, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            SessionHandler(requests: requests, started: started, events: continuation))
                    }
                }
                created.futureResult.whenFailure { started.fail($0) }
            } catch {
                started.fail(error)
            }
        }
        do {
            let child = try await started.futureResult.get()
            deadline.cancel()
            return (child, events)
        } catch {
            deadline.cancel()
            continuation.finish()
            throw error
        }
    }

    func close() async {
        try? await channel.close()
    }

    /// keepalive(行為規格 §7.4:swift-nio-ssh 可自行實作，Android 版 20 秒)。
    ///
    /// swift-nio-ssh 沒有公開送任意 global request 的 API,所以送一個「取消不存在的轉送」
    /// (`cancel-tcpip-forward`,位址是 `.invalid` 網域、埠 0):主機回成功或失敗都證明連線活著，
    /// 而且不會影響任何東西。期限內沒有任何回應 = 半開連線 → 關掉整條連線，下一個指令重新撥號;
    /// 進行中的指令以 `connectionLost` 結束(不重送)。
    private static func startKeepalive(on channel: any Channel, every interval: TimeAmount, replyWithin limit: TimeAmount) {
        let eventLoop = channel.eventLoop
        let task = eventLoop.scheduleRepeatedAsyncTask(initialDelay: interval, delay: interval) { _ in
            let round = eventLoop.makePromise(of: Void.self)
            guard channel.isActive, let handler = try? channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
                round.succeed()
                return round.futureResult
            }
            let reply = eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            // 關閉連線時未回應的請求會失敗，這一輪也就跟著結束。
            let deadline = eventLoop.scheduleTask(in: limit) { channel.close(promise: nil) }
            reply.futureResult.whenComplete { _ in
                deadline.cancel()
                round.succeed()
            }
            handler.sendTCPForwardingRequest(.cancel(host: "purrdr-keepalive.invalid", port: 0), promise: reply)
            return round.futureResult
        }
        channel.closeFuture.whenComplete { _ in task.cancel() }
    }

    private static func connectFailure(_ error: any Error) -> SSHConnectionError {
        if let error = error as? ChannelError, case .connectTimeout = error { return .timedOut }
        if let error = error as? NIOConnectionError {
            if error.connectionErrors.isEmpty { return .hostNotFound }
            let failures = error.connectionErrors.map { connectFailure($0.error) }
            if failures.contains(.connectionRefused) { return .connectionRefused }
            if failures.contains(.timedOut) { return .timedOut }
            return .unreachable
        }
        if let error = error as? IOError {
            switch error.errnoCode {
            case ECONNREFUSED: return .connectionRefused
            case ETIMEDOUT: return .timedOut
            default: return .unreachable
            }
        }
        return .unreachable
    }
}

// MARK: - NIO handlers

/// Tailscale SSH 的 `none` 認證：只提一次，被拒就是不放行。
private final class NoneAuthentication: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var offered = false

    init(username: String) {
        self.username = username
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered else {
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .none))
    }
}

/// host key 驗證：只接受與 pin 相同的 key;沒有 pin 時回報指紋、不登入(行為規格 §8.2)。
private final class HostKeyVerifier: NIOSSHClientServerAuthenticationDelegate {
    private let pin: HostKeyFingerprint?

    init(pin: HostKeyFingerprint?) {
        self.pin = pin
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let presented = try? HostKeyFingerprint(openSSHPublicKey: String(openSSHPublicKey: hostKey)) else {
            validationCompletePromise.fail(SSHConnectionError.unreachable)
            return
        }
        switch pin {
        case nil: validationCompletePromise.fail(SSHConnectionError.hostKeyUnverified(presented: presented))
        case presented?: validationCompletePromise.succeed()
        case let pinned?: validationCompletePromise.fail(SSHConnectionError.hostKeyChanged(presented: presented, pinned: pinned))
        }
    }
}

/// 等認證成功;握手期間的錯誤或斷線讓撥號失敗。之後的錯誤一律關閉連線。
private final class HandshakeHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    private let authenticated: EventLoopPromise<Void>

    init(authenticated: EventLoopPromise<Void>) {
        self.authenticated = authenticated
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { authenticated.succeed() }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        authenticated.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        authenticated.fail(SSHConnectionError.connectionLost)
        context.fireChannelInactive()
    }
}

/// 一個 session channel:開啟後依序送出請求(每個都等主機回覆)，再把資料與結束狀態往上送。
private final class SessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private var requests: [SessionRequest]
    private let started: EventLoopPromise<any Channel>
    private let events: AsyncStream<SessionEvent>.Continuation

    init(requests: [SessionRequest], started: EventLoopPromise<any Channel>, events: AsyncStream<SessionEvent>.Continuation) {
        self.requests = requests
        self.started = started
        self.events = events
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        sendNextRequest(context: context)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            sendNextRequest(context: context)
        case is ChannelFailureEvent:
            started.fail(SSHConnectionError.channelRejected)
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            events.yield(.exitStatus(Int32(truncatingIfNeeded: status.exitStatus)))
        case let signal as SSHChannelRequestEvent.ExitSignal:
            events.yield(.exitSignal(signal.signalName))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        let bytes = Data(buffer.readableBytesView)
        switch message.type {
        case .channel: events.yield(.stdout(bytes))
        case .stdErr: events.yield(.stderr(bytes))
        default: break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        started.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        started.fail(SSHConnectionError.connectionLost)
        events.yield(.closed)
        events.finish()
        context.fireChannelInactive()
    }

    private func sendNextRequest(context: ChannelHandlerContext) {
        guard !requests.isEmpty else {
            started.succeed(context.channel)
            return
        }
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenFailure { [started] error in started.fail(error) }
        switch requests.removeFirst() {
        case .exec(let command):
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: promise)
        case .shell:
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: promise)
        case .pty(let request):
            let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: request.term,
                terminalCharacterWidth: request.columns, terminalRowHeight: request.rows,
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
            context.triggerUserOutboundEvent(pty, promise: promise)
        }
    }
}

// MARK: - 給呼叫端的 session

private func write(_ data: Data, to channel: any Channel) async throws {
    do {
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: data))))
    } catch {
        throw SSHConnectionError.connectionLost
    }
}

/// 一次 exec。結束狀態到了才算正常結束;沒有結束狀態就關閉 = 連線層失敗(不重送)。
private struct SSHExecSession: ExecSession {
    let channel: any Channel
    let output: AsyncThrowingStream<ExecOutput, any Error>

    init(channel: any Channel, events: AsyncStream<SessionEvent>) {
        self.channel = channel
        output = AsyncThrowingStream { continuation in
            let task = Task {
                var code: Int32?
                var signal: String?
                for await event in events {
                    switch event {
                    case .stdout(let data): continuation.yield(.stdout(data))
                    case .stderr(let data): continuation.yield(.stderr(data))
                    case .exitStatus(let status): code = status
                    case .exitSignal(let name): signal = name
                    case .closed: break
                    }
                }
                if let signal {
                    // 與 OpenSSH client 相同：被訊號殺死時回報 255。
                    continuation.yield(.exit(code: code ?? 255, signal: signal))
                    continuation.finish()
                } else if let code {
                    continuation.yield(.exit(code: code))
                    continuation.finish()
                } else {
                    continuation.finish(throwing: SSHConnectionError.connectionLost)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func write(_ data: Data) async throws { try await PurrdrCore.write(data, to: channel) }
    func closeStdin() async { try? await channel.close(mode: .output) }
    func close() async { try? await channel.close() }
}

/// 一個 PTY。stdout 與 stderr 都是畫面輸出。
private struct SSHPTYSession: PTYSession {
    let channel: any Channel
    let output: AsyncThrowingStream<Data, any Error>

    init(channel: any Channel, events: AsyncStream<SessionEvent>) {
        self.channel = channel
        output = AsyncThrowingStream { continuation in
            let task = Task {
                for await event in events {
                    switch event {
                    case .stdout(let data), .stderr(let data): continuation.yield(data)
                    case .exitStatus, .exitSignal, .closed: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func write(_ data: Data) async throws { try await PurrdrCore.write(data, to: channel) }

    func resize(columns: Int, rows: Int) async throws {
        let change = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0)
        do {
            try await channel.triggerUserOutboundEvent(change)
        } catch {
            throw SSHConnectionError.connectionLost
        }
    }

    func close() async { try? await channel.close() }
}
