import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import PurrdrCore

/// SSH 各階段的期限(行為規格 §7.2:每一步都要有明確期限，不依賴函式庫預設)。
public struct SSHTimeouts: Sendable, Equatable {
    /// TCP 連線。
    public var connect: TimeAmount
    /// SSH 握手加上認證。主機接受 TCP 卻永遠不說 SSH 時靠它結束。
    public var handshake: TimeAmount
    /// 開 channel 與等 exec／pty-req 的回覆。
    public var channelOpen: TimeAmount
    /// 連線閒置時多久送一次 keepalive(`nil` 不送);這段時間內主機傳過資料就跳過。iOS 沒有 TCP 層的提早發現，半開連線靠它在使用者動作前就被丟棄。
    public var keepaliveInterval: TimeAmount?
    /// keepalive 送出後等主機回應的期限;到了視為半開連線，整條丟棄(下一個指令重撥)。
    public var keepaliveReply: TimeAmount
    /// 快速偵測斷線(聊天畫面可見)時的 keepalive 間隔與回應期限。最壞偵測時間是兩個間隔加回應期限
    /// (剛收到資料就斷：這一輪跳過，下一輪才送),預設 15 秒;一般間隔是 55 秒。
    public var quickKeepaliveInterval: TimeAmount
    public var quickKeepaliveReply: TimeAmount
    /// Tailscale SSH check mode:收到驗證網址後，等使用者驗證的上限(取代 `handshake`)。
    /// tailscaled 自己最多等約 30 分鐘(`delegateFetchTimeout`),這裡取相同值。
    public var tailscaleCheck: TimeAmount

    public init(
        connect: TimeAmount = .seconds(10), handshake: TimeAmount = .seconds(15), channelOpen: TimeAmount = .seconds(20),
        keepaliveInterval: TimeAmount? = .seconds(20), keepaliveReply: TimeAmount = .seconds(15),
        quickKeepaliveInterval: TimeAmount = .seconds(5), quickKeepaliveReply: TimeAmount = .seconds(5),
        tailscaleCheck: TimeAmount = .minutes(30)
    ) {
        self.quickKeepaliveInterval = quickKeepaliveInterval
        self.quickKeepaliveReply = quickKeepaliveReply
        self.connect = connect
        self.handshake = handshake
        self.channelOpen = channelOpen
        self.keepaliveInterval = keepaliveInterval
        self.keepaliveReply = keepaliveReply
        self.tailscaleCheck = tailscaleCheck
    }
}

/// 真 SSH 的主機通道(ADR-0003:swift-nio-ssh)。
///
/// - 每台主機一條長駐連線，所有指令共用;第一個指令才撥號，同時的撥號合併成一個(行為規格 §7.1)。
/// - 失敗的連線不快取;斷掉的連線在下一個指令前丟棄重撥。
/// - 連線層失敗的指令不自動重送(行為規格 §7.3)。
/// - 沒有 pin 時不登入，回報主機出示的指紋讓使用者確認(TOFU,行為規格 §8.2)。
/// - Tailscale SSH check mode:認證時收到驗證網址就經 `tailscaleCheck` 回報、改用較長的期限等使用者驗證，
///   驗證完連線照常建立，等待中的指令自動繼續。等待期間連線斷了(例如 app 在背景被系統關掉 socket)就重新撥號:
///   還沒登入、指令還沒送出，重撥不違反「不重送」。使用者可經提示取消等待。
public actor SSHHostChannel: HostChannel {
    public nonisolated let endpoint: SSHEndpoint
    private let hostKeyPin: HostKeyFingerprint?
    private let credential: SSHCredentialProvider
    private let timeouts: SSHTimeouts
    private let group: any EventLoopGroup
    private let tailscaleCheck: TailscaleCheckObserver?
    private let scheduler: any SSHDeadlineScheduler
    private let diagnostics: SSHConnectionDiagnostics?
    /// 流量計量(#353):建立後才接上也算(之後開的 channel 起生效)。
    private nonisolated let trafficSink: TrafficSink

    private var connection: SSHConnection?
    private var dial: (id: Int, task: Task<SSHConnection, any Error>)?
    private var dialCount = 0
    /// 使用者取消了這次撥號的 check mode 等待(讓等待中的指令拿到 `.tailscaleCheckCancelled`)。
    private var checkCancelled = false
    /// 要求快速偵測斷線的次數(聊天畫面可見)。
    private var quickDetectionRequests = 0
    private let keepaliveCadence = KeepaliveCadence()

    /// - Parameters:
    ///   - credential: 登入用的憑證，第一次撥號時才取得(Tailscale SSH 是 `none`)。
    ///   - scheduler: 排定 `timeouts` 的時鐘(TCP 連線期限除外)。
    public init(
        endpoint: SSHEndpoint, hostKeyPin: HostKeyFingerprint?, timeouts: SSHTimeouts = SSHTimeouts(),
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        credential: @escaping SSHCredentialProvider = { .none },
        tailscaleCheck: TailscaleCheckObserver? = nil,
        scheduler: any SSHDeadlineScheduler = EventLoopDeadlineScheduler(),
        diagnostics: SSHConnectionDiagnostics? = nil,
        traffic: TrafficRecording? = nil
    ) {
        trafficSink = TrafficSink(traffic)
        self.diagnostics = diagnostics
        self.endpoint = endpoint
        self.hostKeyPin = hostKeyPin
        self.credential = credential
        self.timeouts = timeouts
        group = eventLoopGroup
        self.tailscaleCheck = tailscaleCheck
        self.scheduler = scheduler
    }

    /// 接上流量計量(#353):之後開的 channel 收送的位元組都回報給它。
    public nonisolated func attachTraffic(_ recording: TrafficRecording?) {
        trafficSink.attach(recording)
    }

    public func execute(_ command: String) async throws -> any ExecSession {
        let connection = try await connected()
        do {
            let (channel, events) = try await connection.openSession(
                [.exec(command)], timeout: timeouts.channelOpen, traffic: trafficSink)
            return SSHExecSession(channel: channel, events: events)
        } catch {
            throw drop(connection, after: error)
        }
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        let connection = try await connected()
        let start: SessionRequest = request.command.map { .exec($0) } ?? .shell
        do {
            let (channel, events) = try await connection.openSession(
                [.pty(request), start], timeout: timeouts.channelOpen, traffic: trafficSink)
            return SSHPTYSession(channel: channel, events: events)
        } catch {
            throw drop(connection, after: error)
        }
    }

    /// 開始快速偵測斷線：keepalive 改用短間隔，目前排好的一輪立刻改排。
    public func beginQuickDisconnectDetection() async {
        quickDetectionRequests += 1
        if quickDetectionRequests == 1 { await keepaliveCadence.setQuick(true) }
    }

    /// 結束一次快速偵測;都結束了回到一般間隔。
    public func endQuickDisconnectDetection() async {
        quickDetectionRequests = max(0, quickDetectionRequests - 1)
        if quickDetectionRequests == 0 { await keepaliveCadence.setQuick(false) }
    }

    /// 關掉連線(編輯／刪除主機、信任新 key、app 結束時)。進行中的撥號(含等待 check mode 驗證)一併取消。
    public func disconnect() async {
        dial?.task.cancel()
        dial = nil
        let connection = connection
        self.connection = nil
        await connection?.close(because: .disconnectRequested)
    }

    // MARK: - 連線

    private func connected() async throws -> SSHConnection {
        if let connection {
            if connection.isActive { return connection }
            self.connection = nil
        }
        if let dial {
            do {
                return try await dial.task.value
            } catch {
                throw dialFailure(error)
            }
        }

        dialCount += 1
        let id = dialCount
        checkCancelled = false
        let cancel: @Sendable () async -> Void = { [weak self] in await self?.cancelTailscaleCheck() }
        let task = Task { [endpoint, hostKeyPin, timeouts, group, credential, tailscaleCheck, scheduler, diagnostics, keepaliveCadence] in
            // 讀不到憑證(祕密不在、金鑰壞了)就不撥號。
            let user = try await credential()
            let prompt: @Sendable (URL) -> Void = { url in tailscaleCheck?(TailscaleCheckPrompt(url: url, cancel: cancel)) }
            var prompted = false
            // 與 event loop 轉過來的提示走同一條佇列,維持「提示在前、清除在後」的順序。
            defer { if prompted { SSHCallbackQueue.async { tailscaleCheck?(nil) } } }
            while true {
                do {
                    let (connection, checked) = try await SSHConnection.connect(
                        to: endpoint, credential: user, hostKeyPin: hostKeyPin, timeouts: timeouts, group: group,
                        scheduler: scheduler, cadence: keepaliveCadence, dial: id, diagnostics: diagnostics, onCheck: prompt)
                    prompted = prompted || checked
                    return connection
                } catch let interrupted as CheckInterrupted {
                    prompted = true
                    try Task.checkCancellation()
                    // 等驗證時連線斷了：還沒登入，重撥安全;其他失敗(被拒、逾時)照常回報。
                    guard interrupted.error == .connectionLost else { throw interrupted.error }
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }
        dial = (id, task)
        do {
            let connection = try await task.value
            guard dial?.id == id else {
                // 撥號期間被 disconnect():不要留下沒人管的連線。
                await connection.close(because: .disconnectRequested)
                throw SSHConnectionError.connectionLost
            }
            dial = nil
            self.connection = connection
            return connection
        } catch {
            if dial?.id == id { dial = nil }
            let failure = dialFailure(error)
            if let failure = failure as? SSHConnectionError { diagnostics?(.dialFailed(dial: id, error: failure)) }
            throw failure
        }
    }

    /// 取消等待 check mode 驗證：關掉這次撥號的連線。
    func cancelTailscaleCheck() {
        guard let dial else { return }
        checkCancelled = true
        dial.task.cancel()
    }

    /// 撥號被取消時，依原因換成使用者看得懂的錯誤。
    private func dialFailure(_ error: any Error) -> any Error {
        guard error is CancellationError else { return error }
        return checkCancelled ? SSHConnectionError.tailscaleCheckCancelled : SSHConnectionError.connectionLost
    }

    /// 開 channel 失敗時：連線本身斷了才丟棄(下一個指令重撥);連線健康只讓這個請求失敗(行為規格 §7.3)。
    private func drop(_ failed: SSHConnection, after error: any Error) -> any Error {
        let isActive = failed.isActive
        if !isActive, connection === failed { connection = nil }
        if error as? SSHConnectionError == .timedOut {
            // 期限到被視為半開 socket 的證據：整條連線丟棄(行為規格 §7.2)。
            if connection === failed { connection = nil }
            Task { await failed.close(because: .channelOpenTimeout) }
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
    private let scheduler: any SSHDeadlineScheduler
    private let dropReason: DropReasonBox

    private init(channel: any Channel, scheduler: any SSHDeadlineScheduler, dropReason: DropReasonBox) {
        self.channel = channel
        self.scheduler = scheduler
        self.dropReason = dropReason
    }

    var isActive: Bool { channel.isActive }

    /// 撥號、握手、登入。回傳的 `checked` 表示途中經過 Tailscale SSH check mode。
    ///
    /// 經過 check mode 之後才失敗的，丟 `CheckInterrupted`(呼叫端決定要不要重撥);其他失敗丟 `SSHConnectionError`。
    /// 取消(Task cancellation)會關掉連線。
    static func connect(
        to endpoint: SSHEndpoint, credential: SSHUserCredential, hostKeyPin: HostKeyFingerprint?, timeouts: SSHTimeouts,
        group: any EventLoopGroup, scheduler: any SSHDeadlineScheduler, cadence: KeepaliveCadence, dial: Int,
        diagnostics: SSHConnectionDiagnostics?, onCheck: @escaping @Sendable (URL) -> Void
    ) async throws -> (SSHConnection, checked: Bool) {
        let eventLoop = group.next()
        let dropReason = DropReasonBox()
        let activity = InboundActivityBox()
        let authenticated = eventLoop.makePromise(of: Bool.self)
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(timeouts.connect)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let configuration = SSHClientConfiguration(
                        userAuthDelegate: CredentialAuthentication(username: endpoint.username, credential: credential),
                        serverAuthDelegate: HostKeyVerifier(pin: hostKeyPin))
                    try channel.pipeline.syncOperations.addHandler(InboundActivityHandler(activity: activity))
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(role: .client(configuration), allocator: channel.allocator, inboundChildChannelInitializer: nil))
                    try channel.pipeline.syncOperations.addHandler(
                        HandshakeHandler(
                            authenticated: authenticated, timeouts: timeouts, scheduler: scheduler, dropReason: dropReason, onCheck: onCheck))
                }
            }

        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        } catch {
            authenticated.fail(error)
            throw Self.connectFailure(error)
        }
        do {
            let checked = try await withTaskCancellationHandler {
                try await authenticated.futureResult.get()
            } onCancel: {
                channel.close(promise: nil)
            }
            if let interval = timeouts.keepaliveInterval {
                let rounds = KeepaliveRounds(
                    normal: (interval, timeouts.keepaliveReply), quick: (timeouts.quickKeepaliveInterval, timeouts.quickKeepaliveReply),
                    cadence: cadence)
                startKeepalive(on: channel, rounds: rounds, scheduler: scheduler, dropReason: dropReason, activity: activity)
            }
            // 診斷(#133):登入完成到連線結束的壽命與原因。原因由關閉的一方先記下;都沒記 = 對端關閉。
            diagnostics?(.connected(dial: dial))
            let start = ContinuousClock.now
            // event loop 上不執行注入的程式碼(#470):這個 callback 可能在讀取途中的深 stack 上同步執行,
            // 所以只擷取值,組字串與 os_log 都交給背景佇列。
            channel.closeFuture.whenComplete { _ in
                let raw = dropReason.rawReason
                let lifetime = ContinuousClock.now - start
                SSHCallbackQueue.async { diagnostics?(.dropped(dial: dial, reason: raw?.resolved ?? .closedByPeer, lifetime: lifetime)) }
            }
            return (SSHConnection(channel: channel, scheduler: scheduler, dropReason: dropReason), checked)
        } catch {
            // 握手或認證失敗時一定要關 TCP,否則每次重試留下一個未認證連線(行為規格 §7.1)。
            try? await channel.close()
            if error is CheckInterrupted { throw error }
            throw error as? SSHConnectionError ?? .connectionLost
        }
    }

    func openSession(_ requests: [SessionRequest], timeout: TimeAmount, traffic: TrafficSink) async throws
        -> (any Channel, AsyncStream<SessionEvent>)
    {
        let (events, continuation) = AsyncStream<SessionEvent>.makeStream()
        let channel = self.channel
        let started = channel.eventLoop.makePromise(of: (any Channel).self)
        let deadline = scheduler.schedule(in: timeout, on: channel.eventLoop) {
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
                            SessionHandler(requests: requests, started: started, events: continuation, traffic: traffic))
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

    /// 關閉連線並記下原因(診斷用;已經記過原因就不覆蓋)。
    func close(because reason: SSHDropReason) async {
        dropReason.record(reason)
        try? await channel.close()
    }

    /// keepalive(行為規格 §7.4:swift-nio-ssh 可自行實作，Android 版 20 秒)。
    ///
    /// swift-nio-ssh 沒有公開送任意 global request 的 API,所以送一個「取消不存在的轉送」
    /// (`cancel-tcpip-forward`,位址是 `.invalid` 網域、埠 0):主機回成功或失敗都證明連線活著，
    /// 而且不會影響任何東西。期限內沒有任何回應 = 半開連線 → 關掉整條連線，下一個指令重新撥號;
    /// 進行中的指令以 `connectionLost` 結束(不重送)。這一輪間隔內主機傳過任何資料就已證明連線活著，跳過不送。
    /// 間隔依 `rounds` 目前的節奏(快速偵測斷線時較短);節奏改變時，還在等的那一輪立刻改排。
    private static func startKeepalive(
        on channel: any Channel, rounds: KeepaliveRounds, scheduler: any SSHDeadlineScheduler, dropReason: DropReasonBox,
        activity: InboundActivityBox
    ) {
        let eventLoop = channel.eventLoop
        let nextRound = NIOLoopBoundBox.makeEmptyBox(valueType: SSHScheduledDeadline.self, eventLoop: eventLoop)
        // 上一輪有結果後才排下一輪，間隔從那時算起(與 scheduleRepeatedAsyncTask 相同)。
        @Sendable func scheduleRound(resettingActivity: Bool) {
            guard channel.isActive else { return }
            // 從這裡起算：上一輪 keepalive 自己的回應不算流量。
            if resettingActivity { activity.reset() }
            nextRound.value = scheduler.schedule(in: rounds.current.interval, on: eventLoop) {
                nextRound.value = nil
                guard channel.isActive, let handler = try? channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
                    return
                }
                if activity.receivedData {
                    scheduleRound(resettingActivity: true)
                    return
                }
                let reply = eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
                // 關閉連線時未回應的請求會失敗，這一輪也就跟著結束。
                let deadline = scheduler.schedule(in: rounds.current.reply, on: eventLoop) {
                    dropReason.record(.keepaliveTimeout)
                    channel.close(promise: nil)
                }
                reply.futureResult.whenComplete { _ in
                    deadline.cancel()
                    scheduleRound(resettingActivity: true)
                }
                handler.sendTCPForwardingRequest(.cancel(host: "purrdr-keepalive.invalid", port: 0), promise: reply)
            }
        }
        rounds.cadence.onChange {
            try? await eventLoop.submit {
                // 正在等回應的一輪不動;還在等間隔的一輪照新的節奏重排(保留這段時間收到資料的紀錄)。
                guard let pending = nextRound.value else { return }
                pending.cancel()
                scheduleRound(resettingActivity: false)
            }.get()
        }
        eventLoop.execute { scheduleRound(resettingActivity: true) }
        channel.closeFuture.whenComplete { _ in nextRound.value?.cancel() }
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

/// 在 event loop 上呼叫注入程式碼會用掉 NIO 執行緒有限的 stack(iOS 非主執行緒 512 KB,#470):
/// PurrdrSSH 邊界注入的 closure(診斷、Tailscale check 觀察者)一律先轉到這條背景序列佇列再呼叫。
enum SSHCallbackQueue {
    private static let queue = DispatchQueue(label: "purrdr.ssh-callbacks", qos: .utility)

    static func async(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
}

/// 連線結束的原因：先記下的為準(關閉的一方在關閉前記下;closeFuture 觸發時讀取)。
/// 網路錯誤只存錯誤本身,組成描述字串(可能很吃 stack)留給背景佇列(`RawReason.resolved`)。
final class DropReasonBox: @unchecked Sendable {
    enum RawReason: @unchecked Sendable {
        case reason(SSHDropReason)
        case networkError(any Error)

        var resolved: SSHDropReason {
            switch self {
            case .reason(let reason): reason
            case .networkError(let error): .networkError(String(describing: error))
            }
        }
    }

    private let lock = NSLock()
    private var stored: RawReason?

    var reason: SSHDropReason? { rawReason?.resolved }
    var rawReason: RawReason? { lock.withLock { stored } }

    func record(_ reason: SSHDropReason) { store(.reason(reason)) }
    func record(networkError error: any Error) { store(.networkError(error)) }

    private func store(_ raw: RawReason) {
        lock.withLock { if stored == nil { stored = raw } }
    }
}

/// keepalive 的兩種節奏：一般與快速偵測斷線。
struct KeepaliveRounds: Sendable {
    var normal: (interval: TimeAmount, reply: TimeAmount)
    var quick: (interval: TimeAmount, reply: TimeAmount)
    let cadence: KeepaliveCadence

    var current: (interval: TimeAmount, reply: TimeAmount) { cadence.isQuick ? quick : normal }
}

/// 目前要不要快速偵測斷線(主機通道設定，連線的 keepalive 讀取並在改變時重排)。
final class KeepaliveCadence: @unchecked Sendable {
    private let lock = NSLock()
    private var quick = false
    private var changeHandler: (@Sendable () async -> Void)?

    var isQuick: Bool { lock.withLock { quick } }

    /// 改變時要做的事(目前的連線重排 keepalive);新連線取代舊的。
    func onChange(_ handler: @escaping @Sendable () async -> Void) {
        lock.withLock { changeHandler = handler }
    }

    func setQuick(_ isQuick: Bool) async {
        let handler = lock.withLock { () -> (@Sendable () async -> Void)? in
            guard quick != isQuick else { return nil }
            quick = isQuick
            return changeHandler
        }
        await handler?()
    }
}

/// 上次 `reset()` 之後主機是否傳來過資料(keepalive 據此判斷連線最近有沒有活著的證據)。
final class InboundActivityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var received = false

    var receivedData: Bool { lock.withLock { received } }

    func record() {
        lock.withLock { received = true }
    }

    func reset() {
        lock.withLock { received = false }
    }
}

// MARK: - NIO handlers

/// 把主機傳來的任何資料記到 `InboundActivityBox`。
private final class InboundActivityHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let activity: InboundActivityBox

    init(activity: InboundActivityBox) {
        self.activity = activity
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        activity.record()
        context.fireChannelRead(data)
    }
}

/// 依憑證登入，每種方式只試一次(OpenSSH 會懲罰重複失敗的登入，行為規格 §7.3)。
///
/// - `none`(Tailscale SSH):直接提出 `none`,被拒就是不放行。
/// - 密碼與公鑰：先以 `none` 問主機接受哪些方式(與 OpenSSH client 相同),主機沒開這種方式就不送出祕密。
private final class CredentialAuthentication: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let credential: SSHUserCredential
    private var askedForMethods = false
    private var offered = false

    init(username: String, credential: SSHUserCredential) {
        self.username = username
        self.credential = credential
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered else {
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
            return
        }
        let method: NIOSSHAvailableUserAuthenticationMethods
        let offer: NIOSSHUserAuthenticationOffer.Offer
        switch credential {
        case .none:
            offered = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .none))
            return
        case .password(let password):
            method = .password
            offer = .password(.init(password: password))
        case .privateKey(let key):
            method = .publicKey
            offer = .privateKey(.init(privateKey: key.key))
        }
        guard askedForMethods else {
            askedForMethods = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .none))
            return
        }
        guard availableMethods.contains(method) else {
            nextChallengePromise.fail(SSHConnectionError.authenticationMethodNotAccepted)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer))
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

/// 經過 Tailscale SSH check mode 之後才失敗的撥號(`error` 是原因)。
struct CheckInterrupted: Error {
    let error: SSHConnectionError
}

/// 等認證成功(值 = 途中是否經過 check mode);握手期間的錯誤、斷線或期限到讓撥號失敗。之後的錯誤一律關閉連線。
///
/// 期限從 TCP 連上開始算 `handshake`;收到 Tailscale SSH check mode 的驗證網址後改成 `tailscaleCheck`。
private final class HandshakeHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    private let authenticated: EventLoopPromise<Bool>
    private let timeouts: SSHTimeouts
    private let scheduler: any SSHDeadlineScheduler
    private let dropReason: DropReasonBox
    private let onCheck: @Sendable (URL) -> Void
    private var deadline: SSHScheduledDeadline?
    private var checked = false

    init(
        authenticated: EventLoopPromise<Bool>, timeouts: SSHTimeouts, scheduler: any SSHDeadlineScheduler, dropReason: DropReasonBox,
        onCheck: @escaping @Sendable (URL) -> Void
    ) {
        self.authenticated = authenticated
        self.timeouts = timeouts
        self.scheduler = scheduler
        self.dropReason = dropReason
        self.onCheck = onCheck
    }

    func channelActive(context: ChannelHandlerContext) {
        arm(in: timeouts.handshake, failing: .timedOut, context: context)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is UserAuthSuccessEvent:
            deadline?.cancel()
            authenticated.succeed(checked)
        case let banner as NIOUserAuthBannerEvent:
            if let url = TailscaleCheck.authenticationURL(inBanner: banner.message) {
                checked = true
                arm(in: timeouts.tailscaleCheck, failing: .tailscaleCheckTimedOut, context: context)
                let onCheck = onCheck
                SSHCallbackQueue.async { onCheck(url) }
            }
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(error as? SSHConnectionError ?? .connectionLost)
        dropReason.record(networkError: error)
        context.close(promise: nil)
    }

    /// NIOSSHHandler 不把 channelInactive 往後傳，所以改看 channel 的 closeFuture 判斷握手期間斷線。
    func handlerAdded(context: ChannelHandlerContext) {
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        context.channel.closeFuture.whenComplete { _ in handler.value.fail(.connectionLost) }
    }

    private func arm(in time: TimeAmount, failing error: SSHConnectionError, context: ChannelHandlerContext) {
        deadline?.cancel()
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        deadline = scheduler.schedule(in: time, on: context.eventLoop) { handler.value.fail(error) }
    }

    private func fail(_ error: SSHConnectionError) {
        deadline?.cancel()
        authenticated.fail(checked ? CheckInterrupted(error: error) : error)
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
    private let traffic: TrafficSink

    init(
        requests: [SessionRequest], started: EventLoopPromise<any Channel>, events: AsyncStream<SessionEvent>.Continuation,
        traffic: TrafficSink
    ) {
        self.requests = requests
        self.started = started
        self.events = events
        self.traffic = traffic
    }

    /// 流量計量(#353):這條 channel 寫出的資料(stdin、輸入)。
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .byteBuffer(let buffer) = unwrapOutboundIn(data).data { traffic.record(.sent, buffer.readableBytes) }
        context.write(data, promise: promise)
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
        traffic.record(.received, buffer.readableBytes)
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
            traffic.record(.sent, command.utf8.count)
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

    func write(_ data: Data) async throws { try await PurrdrSSH.write(data, to: channel) }
    func closeStdin() async { try? await channel.close(mode: .output) }
    func close() async { try? await channel.close() }
}

/// 一個 PTY。stdout 與 stderr 都是畫面輸出。
///
/// 程式自己結束(主機送了 exit-status／exit-signal)時輸出正常結束;沒有結束狀態就關閉 = 連線中斷，
/// 丟 `connectionLost`(登入 Shell 依此分辨「已結束」與「連線中斷」)。
private struct SSHPTYSession: PTYSession {
    let channel: any Channel
    let output: AsyncThrowingStream<Data, any Error>

    init(channel: any Channel, events: AsyncStream<SessionEvent>) {
        self.channel = channel
        output = AsyncThrowingStream { continuation in
            let task = Task {
                var exited = false
                for await event in events {
                    switch event {
                    case .stdout(let data), .stderr(let data): continuation.yield(data)
                    case .exitStatus, .exitSignal: exited = true
                    case .closed: break
                    }
                }
                if exited {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: SSHConnectionError.connectionLost)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func write(_ data: Data) async throws { try await PurrdrSSH.write(data, to: channel) }

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
