import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH

/// 登入 Shell(行為規格 F13、GLOSSARY):對主機開 PTY(`pty-req` + `shell`),由 sshd 以登入模式執行使用者預設的 shell,
/// 背後沒有 herdr Pane。尺寸改變以 `window-change` 送出(去抖 250 ms)。
///
/// 跟 Pane 終端機不同:bytes 直接進出 PTY,終端機模擬器看得到程式的模式(bracketed paste、滑鼠),
/// scrollback 也在本機，所以滑動交給模擬器自己捲。
@MainActor
@Observable
public final class LoginShellModel: TerminalSessionModel {
    /// 格數上限(與 Pane 終端機相同)。
    static let maxColumns = 500
    static let maxRows = 200
    /// 貼上的上限。
    static let maxPasteBytes = 256 * 1024
    /// 模擬器接上前暫存的輸出上限，超過丟最舊的。
    static let maxPendingBytes = 2 * 1024 * 1024

    public private(set) var status: TerminalStatus = .waitingForSize
    public private(set) var modifiers: TerminalModifiers = []
    /// 字級只存在記憶體，不持久化(行為規格 §6.4)。
    public private(set) var fontSize: Double = TerminalFontSize.default
    public var notice: String?
    public let title: String
    public var usesRemoteScroll: Bool { false }

    private let channel: any HostChannel
    private let resizeDebounce: Duration
    /// 去抖用的等待;測試注入假的。
    private let sleep: Sleep
    private var size: (columns: Int, rows: Int)?
    private var sentSize: (columns: Int, rows: Int)?
    private var outbox: AsyncStream<Outgoing>.Continuation?
    /// 每開一個新 PTY 加一;舊 PTY 晚到的事件依此丟棄。
    private var generation = 0
    private var resizeTask: Task<Void, Never>?
    private var renderer: ((Data) -> Void)?
    private var pending: [Data] = []
    /// 開不起來的原因(主機的錯誤)。
    private var failure: String?

    public init(
        channel: any HostChannel, title: String, resizeDebounce: Duration = .milliseconds(250),
        sleep: @escaping Sleep = Sleeping.task
    ) {
        self.channel = channel
        self.title = title
        self.resizeDebounce = resizeDebounce
        self.sleep = sleep
    }

    // MARK: - 狀態

    public var statusText: String {
        switch status {
        case .waitingForSize, .connecting: String(localized: "Connecting…")
        case .connected: String(localized: "Connected")
        case .disconnected, .inUse, .takenOver: String(localized: "Connection Lost")
        case .ended: String(localized: "Ended")
        case .unavailable: String(localized: "Unavailable")
        }
    }

    public var bannerText: String? {
        switch status {
        case .waitingForSize, .connecting, .connected: nil
        case .disconnected, .inUse, .takenOver:
            failure.map { String(localized: "Couldn’t open a shell on this host. \($0)") }
                ?? String(localized: "The connection to this host was lost. Reconnect to start a new shell.")
        case .ended: String(localized: "The shell has exited.")
        case .unavailable(let reason): reason
        }
    }

    /// 連線中斷或 shell 結束後都可以再開一個新的 shell(舊的 shell 已經不在了)。
    public var canReconnect: Bool { status == .disconnected || status == .ended }
    public var canTakeOver: Bool { false }

    // MARK: - 畫面

    public func attach(_ renderer: @escaping (Data) -> Void) {
        self.renderer = renderer
        let buffered = pending
        pending = []
        buffered.forEach(renderer)
    }

    public func viewDidResize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        size = (min(columns, Self.maxColumns), min(rows, Self.maxRows))
        if status == .waitingForSize {
            connect()
            return
        }
        resizeTask?.cancel()
        let debounce = resizeDebounce
        let sleep = sleep
        resizeTask = Task { [weak self] in
            try? await sleep(debounce)
            guard !Task.isCancelled else { return }
            self?.sendResizeIfNeeded()
        }
    }

    private func sendResizeIfNeeded() {
        guard let size, status == .connected, sentSize.map({ $0 != size }) ?? true else { return }
        sentSize = size
        outbox?.yield(.resize(columns: size.columns, rows: size.rows))
    }

    // MARK: - 連線

    public func reconnect() {
        guard canReconnect else { return }
        connect()
    }

    public func takeOver() {}

    /// 掛斷：關閉 PTY(主機送 SIGHUP 給 shell)。不會自動重連。
    public func hangUp() {
        resizeTask?.cancel()
        generation += 1
        outbox?.yield(.close)
        outbox?.finish()
        outbox = nil
        switch status {
        case .connecting, .connected: status = .disconnected
        default: break
        }
    }

    private func connect() {
        guard let size else { return }
        outbox?.finish()
        generation += 1
        let generation = generation
        status = .connecting
        failure = nil
        sentSize = size
        let (outgoing, outbox) = AsyncStream<Outgoing>.makeStream()
        self.outbox = outbox
        let channel = channel
        Task { [weak self] in
            let session: any PTYSession
            do {
                session = try await channel.openPTY(PTYRequest(columns: size.columns, rows: size.rows))
            } catch {
                self?.failed(error, generation: generation)
                return
            }
            guard let self, self.generation == generation else {
                await session.close()
                return
            }
            self.status = .connected
            // 開啟期間尺寸變了：pty-req 用的是舊格數，補送一次。
            self.sendResizeIfNeeded()
            // 輸入依序寫出:同一個 PTY 只有這一個寫入者。
            let writer = Task {
                for await message in outgoing {
                    switch message {
                    case .bytes(let data): try? await session.write(data)
                    case .resize(let columns, let rows): try? await session.resize(columns: columns, rows: rows)
                    case .close: await session.close()
                    }
                }
            }
            var ended: TerminalStatus = .ended
            do {
                for try await chunk in session.output {
                    guard self.generation == generation else { break }
                    self.render(chunk)
                }
            } catch {
                ended = .disconnected
            }
            writer.cancel()
            if self.generation == generation, self.status == .connected {
                self.outbox?.finish()
                self.outbox = nil
                self.status = ended
            }
        }
    }

    private func failed(_ error: any Error, generation: Int) {
        guard self.generation == generation else { return }
        outbox?.finish()
        outbox = nil
        failure = HostErrorText.message(for: error)
        status = .disconnected
    }

    private func render(_ bytes: Data) {
        if let renderer {
            renderer(bytes)
            return
        }
        pending.append(bytes)
        var total = pending.reduce(0) { $0 + $1.count }
        while total > Self.maxPendingBytes, pending.count > 1 {
            total -= pending.removeFirst().count
        }
    }

    // MARK: - 輸入

    public func type(_ data: Data) {
        guard isInteractive else { return }
        if !modifiers.isEmpty, let text = String(data: data, encoding: .utf8), text.count == 1, let character = text.first {
            press(.character(character))
            return
        }
        outbox?.yield(.bytes(data))
    }

    public func press(_ key: TerminalKey, adding extraModifiers: TerminalModifiers, applicationCursor: Bool) {
        guard isInteractive else { return }
        outbox?.yield(.bytes(key.bytes(modifiers: modifiers.union(extraModifiers))))
        modifiers = []
    }

    public func toggle(_ modifier: TerminalModifiers) {
        modifiers.formSymmetricDifference(modifier)
    }

    /// 貼上：程式開了 bracketed paste 模式時才包標記(模擬器看得到 PTY 的模式)。
    public func paste(_ text: String, bracketed: Bool) {
        guard isInteractive, !text.isEmpty else { return }
        let body = Data(text.utf8)
        guard body.count <= Self.maxPasteBytes else {
            notice = String(localized: "This paste is too large to send to the terminal.")
            return
        }
        outbox?.yield(.bytes(bracketed ? Data("\u{1B}[200~".utf8) + body + Data("\u{1B}[201~".utf8) : body))
    }

    /// 登入 Shell 的滑動由模擬器自己捲 scrollback,不經 model。
    public func scroll(_ direction: TerminalInput.ScrollDirection, rows: Int, column: Int, row: Int) {}

    public func scrollPage(_ direction: TerminalInput.ScrollDirection, rows: Int) {}

    // MARK: - 字級

    public func setFontSize(_ size: Double) {
        fontSize = TerminalFontSize.clamped(size)
    }

    private enum Outgoing {
        case bytes(Data)
        case resize(columns: Int, rows: Int)
        case close
    }
}
