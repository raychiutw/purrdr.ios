import Crypto
import Foundation
import NIOCore
import NIOPosix
// 送出「認證中」的橫幅要用到 NIOSSHHandler 的 internal API(公開 API 只能把橫幅跟認證成功綁在一起送)。
@testable import NIOSSH
import PurrdrCore
import Synchronization

/// 測試用的 SSH 伺服器(swift-nio-ssh 的 server 角色),在本機 127.0.0.1 隨機埠上跑。
///
/// 模擬 Tailscale SSH:只接受 `none` 認證。每個 exec 依 `behavior` 決定怎麼回應，並記錄連線數、
/// 收到的指令與 PTY 請求，讓測試從外部斷言主機通道的行為(連線重用、不重送、TOFU)。
///
/// `auth` 依連線序號(從 1 起算)決定認證方式，可模擬 Tailscale SSH check mode:先送認證橫幅、
/// 不回覆認證結果，過一段時間才放行／拒絕／斷線(依文件模擬，見 `docs/research/tailscale-ssh-check-mode.md`)。
final class TestSSHServer: Sendable {
    /// `none` 認證的處理方式。
    enum Auth: Sendable {
        /// 立即放行。
        case accept
        /// check mode:送出 `banner` 後先不回覆，再依 `then` 收尾。
        case check(banner: String, then: CheckResult)
    }

    /// check mode 等待後的結果。
    enum CheckResult: Sendable {
        /// 使用者在瀏覽器完成驗證：過 `after` 後放行。
        case approve(after: TimeAmount)
        /// 驗證被拒：過 `after` 後回認證失敗。
        case deny(after: TimeAmount)
        /// 過 `after` 後切斷 TCP(例如 app 進背景時連線被系統關掉)。
        case drop(after: TimeAmount)
        /// 一直不回覆。
        case hold
    }

    /// 一個 exec 指令的回應方式。
    enum Behavior: Sendable {
        /// 立即回應後結束。
        case reply(stdout: String = "", stderr: String = "", exitCode: Int32 = 0)
        /// 被訊號殺死(SSH `exit-signal`)。
        case killed(signal: String)
        /// 像 `herdr remote-api-bridge`:等 stdin 收到一行，回 `"echo:" + 那一行`,結束。
        case echoFirstLine
        /// 收到指令後直接切斷整條 TCP 連線(連線層失敗)。
        case dropConnection
        /// 用本機 `/bin/sh -c` 真的執行(接上 stdin／stdout／stderr)。
        case runLocally
    }

    struct PTYRecord: Sendable, Equatable {
        var term: String
        var columns: Int
        var rows: Int
        var command: String?
        var windowChanges: [[Int]] = []
        var input = Data()
    }

    struct Log: Sendable {
        var connections = 0
        /// 已關閉的連線數。
        var disconnections = 0
        /// 送出的 check mode 橫幅數。
        var checkBanners = 0
        var usernames: [String] = []
        var commands: [String] = []
        var ptys: [PTYRecord] = []
    }

    let port: Int
    let hostKey: NIOSSHPrivateKey
    private let channel: any Channel
    private let log: Mutex<Log>

    var fingerprint: HostKeyFingerprint {
        try! HostKeyFingerprint(openSSHPublicKey: String(openSSHPublicKey: hostKey.publicKey))
    }

    var snapshot: Log { log.withLock { $0 } }

    var endpoint: SSHEndpoint { SSHEndpoint(host: "127.0.0.1", port: port, username: "demo") }

    private init(port: Int, hostKey: NIOSSHPrivateKey, channel: any Channel) {
        self.port = port
        self.hostKey = hostKey
        self.channel = channel
        self.log = Mutex(Log())
    }

    static func start(
        auth: @escaping @Sendable (_ connection: Int) -> Auth = { _ in .accept },
        behavior: @escaping @Sendable (String) -> Behavior
    ) async throws -> TestSSHServer {
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let recorder = Recorder()
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let number = recorder.nextConnection()
                recorder.update { $0.connections += 1 }
                channel.closeFuture.whenComplete { _ in recorder.update { $0.disconnections += 1 } }
                return channel.eventLoop.makeCompletedFuture {
                    let delegate = AcceptNoneDelegate(recorder: recorder, auth: auth(number), connection: channel)
                    let handler = NIOSSHHandler(
                        role: .server(.init(hostKeys: [hostKey], userAuthDelegate: delegate)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, _ in
                            child.eventLoop.makeCompletedFuture {
                                try child.pipeline.syncOperations.addHandler(
                                    ServerSessionHandler(recorder: recorder, behavior: behavior, parent: channel))
                            }
                        })
                    try channel.pipeline.syncOperations.addHandler(handler)
                    try channel.pipeline.syncOperations.addHandler(CloseOnErrorHandler())
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let server = TestSSHServer(port: channel.localAddress!.port!, hostKey: hostKey, channel: channel)
        recorder.attach(server)
        return server
    }

    func stop() async {
        try? await channel.close()
    }

    fileprivate func record(_ change: (inout Log) -> Void) {
        log.withLock { change(&$0) }
    }
}

/// 連到 server 之前 server 還沒建好，所以先收集、建好後再寫進 server 的 log。
private final class Recorder: Sendable {
    private let state = Mutex<(server: TestSSHServer?, pending: [@Sendable (inout TestSSHServer.Log) -> Void])>((nil, []))
    private let connectionCount = Mutex(0)

    /// 新連線的序號(從 1 起算)。
    func nextConnection() -> Int {
        connectionCount.withLock { count in
            count += 1
            return count
        }
    }

    func attach(_ server: TestSSHServer) {
        let pending = state.withLock { state in
            state.server = server
            defer { state.pending = [] }
            return state.pending
        }
        for change in pending { server.record(change) }
    }

    func update(_ change: @escaping @Sendable (inout TestSSHServer.Log) -> Void) {
        let server = state.withLock { state -> TestSSHServer? in
            if state.server == nil { state.pending.append(change) }
            return state.server
        }
        server?.record(change)
    }
}

private final class AcceptNoneDelegate: NIOSSHServerUserAuthenticationDelegate, Sendable {
    let recorder: Recorder
    let auth: TestSSHServer.Auth
    let connection: any Channel

    init(recorder: Recorder, auth: TestSSHServer.Auth, connection: any Channel) {
        self.recorder = recorder
        self.auth = auth
        self.connection = connection
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }

    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        let username = request.username
        recorder.update { $0.usernames.append(username) }
        guard case .none = request.request else {
            responsePromise.succeed(.failure)
            return
        }
        switch auth {
        case .accept:
            responsePromise.succeed(.success)
        case .check(let banner, let result):
            sendBanner(banner)
            recorder.update { $0.checkBanners += 1 }
            let loop = connection.eventLoop
            switch result {
            case .approve(let delay):
                loop.scheduleTask(in: delay) { responsePromise.succeed(.success) }
            case .deny(let delay):
                loop.scheduleTask(in: delay) { responsePromise.succeed(.failure) }
            case .drop(let delay):
                loop.scheduleTask(in: delay) { [connection] in
                    connection.close(promise: nil)
                    responsePromise.fail(ChannelError.ioOnClosedChannel)
                }
            case .hold:
                // 不回覆;連線關閉時才讓 promise 結束，避免 promise 洩漏。
                connection.closeFuture.whenComplete { _ in responsePromise.fail(ChannelError.ioOnClosedChannel) }
            }
        }
    }

    /// 在認證進行中送出 SSH_MSG_USERAUTH_BANNER(Tailscale 的 `SendAuthBanner`)。
    /// 這裡還在 handler 處理收到的認證請求途中，排到下一輪 event loop 才寫，避免重入 handler。
    private func sendBanner(_ message: String) {
        connection.eventLoop.execute { [connection] in
            Self.write(banner: message, on: connection)
        }
    }

    private static func write(banner message: String, on connection: any Channel) {
        guard let handler = try? connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else { return }
        handler.writeFromChildChannel(.userAuthBanner(.init(message: message, languageTag: "")), nil)
        handler.flushFromChildChannel()
    }
}

private final class CloseOnErrorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

/// server 端的一個 session channel:處理 exec、pty-req、shell、window-change。
private final class ServerSessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let recorder: Recorder
    private let behavior: @Sendable (String) -> TestSSHServer.Behavior
    private let parent: any Channel
    private var mode: Mode = .idle
    private var stdin = Data()
    private var ptyIndex: Int?
    private var process: Process?
    private var processInput: FileHandle?

    private enum Mode {
        case idle
        case echoFirstLine
        case pty
        case process
        case done
    }

    init(recorder: Recorder, behavior: @escaping @Sendable (String) -> TestSSHServer.Behavior, parent: any Channel) {
        self.recorder = recorder
        self.behavior = behavior
        self.parent = parent
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let request as SSHChannelRequestEvent.ExecRequest:
            let command = request.command
            recorder.update { $0.commands.append(command) }
            if mode == .pty {
                recorder.update { log in log.ptys[log.ptys.count - 1].command = command }
                reply(request.wantReply, context: context)
                write(Data("pty$ ".utf8), type: .channel, context: context)
                return
            }
            reply(request.wantReply, context: context)
            run(behavior(command), command: command, context: context)
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            mode = .pty
            let record = TestSSHServer.PTYRecord(term: request.term, columns: request.terminalCharacterWidth, rows: request.terminalRowHeight)
            recorder.update { $0.ptys.append(record) }
            reply(request.wantReply, context: context)
        case let request as SSHChannelRequestEvent.ShellRequest:
            reply(request.wantReply, context: context)
            write(Data("pty$ ".utf8), type: .channel, context: context)
        case let request as SSHChannelRequestEvent.WindowChangeRequest:
            let size = [request.terminalCharacterWidth, request.terminalRowHeight]
            recorder.update { log in log.ptys[log.ptys.count - 1].windowChanges.append(size) }
        case let event as ChannelEvent where event == .inputClosed:
            try? processInput?.close()
            processInput = nil
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        let bytes = Data(buffer.readableBytesView)
        switch mode {
        case .echoFirstLine:
            stdin.append(bytes)
            if let newline = stdin.firstIndex(of: 0x0A) {
                mode = .done
                write(Data("echo:".utf8) + stdin[..<newline] + [0x0A], type: .channel, context: context)
                exit(0, context: context)
            }
        case .pty:
            recorder.update { log in log.ptys[log.ptys.count - 1].input.append(bytes) }
            write(bytes, type: .channel, context: context)
        case .process:
            processInput?.write(bytes)
        case .idle, .done:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let process, process.isRunning { process.terminate() }
        context.fireChannelInactive()
    }

    private func run(_ behavior: TestSSHServer.Behavior, command: String, context: ChannelHandlerContext) {
        switch behavior {
        case .reply(let stdout, let stderr, let exitCode):
            if !stdout.isEmpty { write(Data(stdout.utf8), type: .channel, context: context) }
            if !stderr.isEmpty { write(Data(stderr.utf8), type: .stdErr, context: context) }
            exit(exitCode, context: context)
        case .killed(let signal):
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExitSignal(signalName: signal, errorMessage: "", language: "", dumpedCore: false),
                promise: nil)
            context.close(promise: nil)
        case .echoFirstLine:
            mode = .echoFirstLine
        case .dropConnection:
            parent.close(promise: nil)
        case .runLocally:
            mode = .process
            startProcess(command, channel: context.channel)
        }
    }

    private func startProcess(_ command: String, channel: any Channel) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        self.process = process
        processInput = input.fileHandleForWriting
        let group = DispatchGroup()
        for (pipe, type) in [(output, SSHChannelData.DataType.channel), (error, .stdErr)] {
            group.enter()
            DispatchQueue.global().async {
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    channel.writeAndFlush(SSHChannelData(type: type, data: .byteBuffer(ByteBuffer(bytes: data))), promise: nil)
                }
                group.leave()
            }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            group.notify(queue: .global()) {
                channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: Int(status))).whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
        }
        try? process.run()
    }

    private func reply(_ wantReply: Bool, context: ChannelHandlerContext) {
        if wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
    }

    private func write(_ data: Data, type: SSHChannelData.DataType, context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: type, data: .byteBuffer(ByteBuffer(bytes: data)))), promise: nil)
    }

    private func exit(_ code: Int32, context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: Int(code)), promise: nil)
        context.close(promise: nil)
    }
}
