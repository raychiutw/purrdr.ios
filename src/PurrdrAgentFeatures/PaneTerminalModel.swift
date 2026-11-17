import Foundation
import Observation
import PurrdrCore

/// Pane 終端機畫面的 model:管一條 `terminal session control` 連線的生命週期、按鍵列、尺寸與字級。
///
/// 畫面(終端機模擬器)只負責畫;滑動、貼上、按鍵一律經過這裡變成 herdr 的訊息(#4 spike 的要求：
/// herdr 不轉送終端機模式，模擬器自己編碼滑鼠或滾輪一定會錯)。
@MainActor
@Observable
public final class PaneTerminalModel: TerminalSessionModel {
    public typealias Status = TerminalStatus

    /// 字級範圍：小於 8pt 讀不了;大於 28pt 直立 iPad 放不下 80 欄(行為規格 §6.4)。
    public static let fontSizes = TerminalFontSize.range
    public static let defaultFontSize = TerminalFontSize.default
    /// 格數上限：herdr 會接受 5000 欄並回很大的 full frame。
    package static let maxColumns = 500
    package static let maxRows = 200
    /// 貼上的上限。貼上必須一則送完(切塊後就不是完整的 bracketed paste);herdr 單則上限 1 MiB(含 base64 膨脹)。
    package static let maxPasteBytes = 256 * 1024
    /// 模擬器接上前暫存的輸出上限，超過丟最舊的。
    package static let maxPendingBytes = 2 * 1024 * 1024

    public private(set) var status: Status = .waitingForSize
    /// 鎖定中的黏著修飾鍵。
    public private(set) var modifiers: TerminalModifiers = []
    /// 字級只存在記憶體，不持久化(刻意，行為規格 §6.4)。
    public private(set) var fontSize: Double = PaneTerminalModel.defaultFontSize
    /// 一次性的提示(例如貼上太大)。
    public var notice: String?
    public let paneID: String
    public let title: String

    private let client: PaneTerminalClient
    private let resizeDebounce: Duration
    /// 去抖用的等待;測試注入假的。
    private let sleep: @Sendable (Duration) async throws -> Void
    private var size: (columns: Int, rows: Int)?
    private var sentSize: (columns: Int, rows: Int)?
    private var outbox: AsyncStream<Outgoing>.Continuation?
    /// 每開一條新連線加一;舊連線晚到的事件依此丟棄。
    private var generation = 0
    private var resizeTask: Task<Void, Never>?
    private var renderer: ((Data) -> Void)?
    private var pending: [Data] = []

    public init(
        client: PaneTerminalClient, paneID: String, title: String, resizeDebounce: Duration = .milliseconds(250),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.paneID = paneID
        self.title = title
        self.resizeDebounce = resizeDebounce
        self.sleep = sleep
    }

    // MARK: - 狀態

    public var statusText: String {
        switch status {
        case .waitingForSize, .connecting: String(localized: "Connecting…")
        case .connected: String(localized: "Connected")
        case .disconnected: String(localized: "Connection Lost")
        case .inUse: String(localized: "In Use Elsewhere")
        case .takenOver: String(localized: "Taken Over")
        case .ended: String(localized: "Ended")
        case .unavailable: String(localized: "Unavailable")
        }
    }

    /// 橫幅說明。已連線時沒有。
    public var bannerText: String? {
        switch status {
        case .waitingForSize, .connecting, .connected: nil
        case .disconnected: String(localized: "Reconnect to pick up where this pane is now.")
        case .inUse: String(localized: "Someone else is controlling this pane. Take over to use it here.")
        case .takenOver: String(localized: "Another device took over this pane.")
        case .ended: String(localized: "The program in this pane has exited.")
        case .unavailable(let reason): reason
        }
    }

    public var canReconnect: Bool { status == .disconnected }
    /// 只有被拒或被接管時才提供接管——首次開啟與重新連線都不自動搶(行為規格 §6.3)。
    public var canTakeOver: Bool { status == .inUse || status == .takenOver }
    /// 按鍵列與貼上是否可用。
    public var isInteractive: Bool { status == .connected }
    /// 本機 scrollback 是空的(herdr 每次都重畫整個 viewport):滑動送 `terminal.scroll`。
    public var usesRemoteScroll: Bool { true }

    // MARK: - 畫面

    /// 接上終端機模擬器。之前暫存的輸出依序補畫。
    public func attach(_ renderer: @escaping (Data) -> Void) {
        self.renderer = renderer
        let buffered = pending
        pending = []
        buffered.forEach(renderer)
    }

    /// 畫面依字級與邊界算出的格數。第一次回報時才開連線;之後去抖再送給主機。
    public func viewDidResize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        let clamped = (columns: min(columns, Self.maxColumns), rows: min(rows, Self.maxRows))
        size = clamped
        if status == .waitingForSize {
            connect(takeover: false)
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
        outbox?.yield(.input(.resize(columns: size.columns, rows: size.rows)))
    }

    // MARK: - 連線

    public func reconnect() {
        guard canReconnect else { return }
        connect(takeover: false)
    }

    public func takeOver() {
        guard canTakeOver else { return }
        connect(takeover: true)
    }

    /// 掛斷：送 release、關閉通道(離開畫面、App 進背景)。不會自動重連。
    public func hangUp() {
        resizeTask?.cancel()
        generation += 1
        outbox?.yield(.release)
        outbox?.finish()
        outbox = nil
        switch status {
        case .connecting, .connected: status = .disconnected
        default: break
        }
    }

    private func connect(takeover: Bool) {
        guard let size else { return }
        outbox?.finish()
        generation += 1
        let generation = generation
        status = .connecting
        sentSize = size
        let (outgoing, outbox) = AsyncStream<Outgoing>.makeStream()
        self.outbox = outbox
        let client = client
        let paneID = paneID
        Task { [weak self] in
            let connection: PaneTerminalConnection
            do {
                connection = try await client.control(
                    target: paneID, columns: size.columns, rows: size.rows, takeover: takeover
                )
            } catch {
                self?.finish(.disconnected, generation: generation)
                return
            }
            // 輸入依序寫出:同一條連線只有這一個寫入者。
            let writer = Task {
                for await message in outgoing {
                    switch message {
                    case .bytes(let data): try? await connection.send(bytes: data)
                    case .input(let input): try? await connection.send(input)
                    case .release: await connection.release()
                    }
                }
                await connection.release()
            }
            for await event in connection.events {
                guard let self, self.generation == generation else { break }
                self.handle(event)
            }
            writer.cancel()
            if let self, self.generation == generation, self.status == .connecting || self.status == .connected {
                self.status = .disconnected
            }
        }
    }

    private func handle(_ event: PaneTerminalEvent) {
        switch event {
        case .frame(let frame):
            if status == .connecting {
                status = .connected
                // 開啟期間尺寸變了：handshake 用的是舊格數，補送一次。
                sendResizeIfNeeded()
            }
            render(frame.bytes)
        case .closed(let reason):
            finish(Self.status(for: reason), generation: generation)
        case .disconnected:
            finish(.disconnected, generation: generation)
        case .failed(_, let message):
            finish(.unavailable(message.contains("command not found")
                ? String(localized: "herdr isn’t installed on this host, or isn’t on its PATH.")
                : (message.isEmpty ? String(localized: "herdr couldn’t open this pane.") : message)), generation: generation)
        }
    }

    private static func status(for reason: TerminalCloseReason) -> Status {
        switch reason {
        case .detached: .disconnected
        case .takenOver: .takenOver
        case .alreadyAttached: .inUse
        case .notFound: .unavailable(String(localized: "This pane no longer exists on the host."))
        case .exited: .ended
        case .other: .disconnected
        }
    }

    private func finish(_ status: Status, generation: Int) {
        guard self.generation == generation else { return }
        outbox?.finish()
        outbox = nil
        self.status = status
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

    /// 終端機模擬器送出的鍵盤輸入(軟體或硬體鍵盤)。鎖定了 Ctrl／Alt 時，下一個字元帶著修飾送出。
    public func type(_ data: Data) {
        guard isInteractive else { return }
        if !modifiers.isEmpty, let text = String(data: data, encoding: .utf8), text.count == 1, let character = text.first {
            press(.character(character))
            return
        }
        outbox?.yield(.bytes(data))
    }

    /// 按鍵列的一顆鍵。帶著鎖定中的修飾鍵編碼，送出後放開修飾鍵。
    public func press(_ key: TerminalKey) {
        guard isInteractive else { return }
        outbox?.yield(.bytes(key.bytes(modifiers: modifiers)))
        modifiers = []
    }

    /// 切換黏著修飾鍵。
    public func toggle(_ modifier: TerminalModifiers) {
        modifiers.formSymmetricDifference(modifier)
    }

    /// 貼上：永遠包 bracketed paste 標記，由 herdr 依 Pane 的模式決定要不要保留(模擬器看不到 Pane 的模式)。
    public func paste(_ text: String, bracketed: Bool) {
        paste(text)
    }

    public func paste(_ text: String) {
        guard isInteractive, !text.isEmpty else { return }
        let body = Data(text.utf8)
        guard body.count <= Self.maxPasteBytes else {
            notice = String(localized: "This paste is too large to send to the terminal.")
            return
        }
        outbox?.yield(.input(.bytes(Data("\u{1B}[200~".utf8) + body + Data("\u{1B}[201~".utf8))))
    }

    /// 單指滑過 `rows` 列。每列送一則 `lines: 1`:程式自己處理滾輪時(vim、less),一則只算一格。
    public func scroll(_ direction: TerminalInput.ScrollDirection, rows: Int, column: Int, row: Int) {
        guard isInteractive, rows > 0 else { return }
        for _ in 0..<rows {
            outbox?.yield(.input(.scroll(direction, lines: 1, column: max(0, column), row: max(0, row))))
        }
    }

    // MARK: - 字級

    public func setFontSize(_ size: Double) {
        fontSize = TerminalFontSize.clamped(size)
    }

    // MARK: - 連結

    /// 只開 http／https 連結;其他 scheme 一律忽略。
    public static func openableURL(_ link: String) -> URL? {
        TerminalLinks.openableURL(link)
    }

    private enum Outgoing {
        case bytes(Data)
        case input(TerminalInput)
        case release
    }
}
