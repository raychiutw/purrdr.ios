import Foundation

/// 開 Pane 終端機的 client:經主機連線接上 pane(SSH 是執行 `herdr terminal session control`,ADR-0005)。
///
/// 協定的實測行為見 `docs/research/terminal-session-control-macos.md`。wire format(NDJSON、snake_case)
/// 只在這個檔案處理。
public struct PaneTerminalClient: Sendable {
    private let connection: any HostConnection

    public init(connection: any HostConnection) {
        self.connection = connection
    }

    /// SSH 連線方式(主機通道)的捷徑。
    public init(channel: any HostChannel, herdr: HerdrInstallation = HerdrInstallation()) {
        self.init(connection: SSHHostConnection(channel: channel, herdr: herdr))
    }

    /// 以 controller 身分接上 `target`(pane id 或 terminal id),以 `columns`×`rows` 做 handshake。
    public func control(target: String, columns: Int, rows: Int, takeover: Bool = false) async throws -> PaneTerminalConnection {
        try await connection.openPaneTerminal(target: target, columns: columns, rows: rows, takeover: takeover)
    }
}

/// 一條 Pane 終端機連線。`events` 結束時連線就結束了;要再接上得開新連線。
public actor PaneTerminalConnection {
    /// 主機送來的事件，依到達順序。最後一個一定是 `.closed`、`.disconnected` 或 `.failed`。
    public nonisolated let events: AsyncStream<PaneTerminalEvent>

    private let session: any ExecSession
    private var reader: Task<Void, Never>?

    init(session: any ExecSession) {
        self.session = session
        let (events, continuation) = AsyncStream<PaneTerminalEvent>.makeStream()
        self.events = events
        reader = Task { await Self.read(session.output, into: continuation) }
    }

    /// 送一則輸入。
    public func send(_ input: TerminalInput) async throws {
        try await session.write(input.line)
    }

    /// 送出鍵盤輸入的 bytes。超過單則上限時切成多則(herdr 收到 > 1 MiB 的單則輸入會直接斷線，不送 closed)。
    public func send(bytes: Data) async throws {
        for chunk in TerminalInput.chunks(of: bytes) {
            try await send(chunk)
        }
    }

    /// 放開 controller:送 `terminal.release` 後關閉通道。主機會恢復桌機的 pane 尺寸。
    public func release() async {
        try? await session.write(TerminalInput.release.line)
        await session.closeStdin()
        await session.close()
        reader?.cancel()
    }

    // MARK: - 讀 stdout

    private static func read(
        _ output: AsyncThrowingStream<ExecOutput, any Error>, into continuation: AsyncStream<PaneTerminalEvent>.Continuation
    ) async {
        var buffer = Data()
        var stderr = Data()
        var exitCode: Int32 = 0
        do {
            for try await event in output {
                switch event {
                case .stdout(let data):
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        switch TerminalStreamLine(line) {
                        case .frame(let frame):
                            continuation.yield(.frame(frame))
                        case .closed(let reason):
                            continuation.yield(.closed(reason))
                            continuation.finish()
                            return
                        case nil:
                            continue
                        }
                    }
                case .stderr(let data):
                    stderr.append(data)
                case .exit(let code, _):
                    exitCode = code
                }
            }
        } catch {
            continuation.yield(.disconnected)
            continuation.finish()
            return
        }
        // 沒收到 terminal.closed 就結束：exit 0 是連線被切(超大輸入、client 被殺、通道斷);
        // 非 0 是 herdr 根本沒跑起來(找不到 herdr、handshake 失敗)。
        if exitCode == 0 {
            continuation.yield(.disconnected)
        } else {
            let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.yield(.failed(exitCode: exitCode, message: message))
        }
        continuation.finish()
    }
}

/// Pane 終端機連線上的事件。
public enum PaneTerminalEvent: Sendable, Equatable {
    /// 一次畫面更新。
    case frame(TerminalFrame)
    /// herdr 結束了這條連線，並說明原因。
    case closed(TerminalCloseReason)
    /// 沒有收到 `terminal.closed` 就斷了:可以重新連線。不要看 exit code(一律是 0)。
    case disconnected
    /// herdr 沒有跑起來(例如主機上找不到 herdr),`message` 是 stderr。
    case failed(exitCode: Int32, message: String)
}

/// 一個 `terminal.frame`:可以直接餵給終端機模擬器的 ANSI bytes。
public struct TerminalFrame: Sendable, Equatable {
    /// 每條連線從 1 起算。
    public var seq: UInt64
    public var columns: Int
    public var rows: Int
    /// `true` 是完整重繪(第一個 frame、resize 後、擁有權變動時),`false` 是增量差異。
    public var full: Bool
    public var bytes: Data

    public init(seq: UInt64, columns: Int, rows: Int, full: Bool, bytes: Data) {
        self.seq = seq
        self.columns = columns
        self.rows = rows
        self.full = full
        self.bytes = bytes
    }
}

/// `terminal.closed` 的原因。herdr 只給人讀的字串，這裡依實測過的原文分類。
public enum TerminalCloseReason: Sendable, Equatable {
    /// 我方 release 或關閉 stdin。
    case detached
    /// 別的 client 以 `--takeover` 接管了。
    case takenOver
    /// 已經有別的 client 在操作這個 pane,要「接管」才能接上。
    case alreadyAttached
    /// 主機上沒有這個 pane。
    case notFound
    /// pane 裡的程式結束了。herdr 不提供 exit code。
    case exited
    /// 其他原因，保留 herdr 原文(例如 `server is shutting down`)。
    case other(String)

    public init(herdr reason: String?) {
        let reason = reason ?? ""
        if reason == "detached" {
            self = .detached
        } else if reason == "terminal attach taken over" {
            self = .takenOver
        } else if reason.contains("already has an attached client") {
            self = .alreadyAttached
        } else if reason.hasSuffix(" not found") {
            self = .notFound
        } else if reason.hasPrefix("terminal "), reason.hasSuffix(" exited") {
            self = .exited
        } else {
            self = .other(reason)
        }
    }
}

/// 送進 control stdin 的一則訊息。
public enum TerminalInput: Sendable, Equatable {
    /// 鍵盤輸入的原始 bytes。
    case bytes(Data)
    /// 改變 viewport 格數。主機的 pane PTY 會跟著改，並回一個 full frame。
    case resize(columns: Int, rows: Int)
    /// 捲動。主機依 pane 狀態決定捲主機端 scrollback、送滾輪事件或方向鍵;
    /// 程式自己處理滾輪時 `lines` 會被忽略，所以每滑過一列送一則 `lines: 1`。
    case scroll(ScrollDirection, lines: Int = 1, column: Int, row: Int)
    /// 放開 controller。
    case release

    public enum ScrollDirection: String, Sendable {
        case up
        case down
    }

    /// 單則輸入的上限。herdr 的硬上限是 1 MiB(超過直接斷線);這裡留很大的餘裕。
    public static let maxChunk = 64 * 1024

    /// 把輸入切成每則不超過 `maxChunk` 的 `.bytes`。
    public static func chunks(of data: Data) -> [TerminalInput] {
        stride(from: 0, to: data.count, by: maxChunk).map { offset in
            let start = data.startIndex + offset
            return .bytes(Data(data[start..<min(start + maxChunk, data.endIndex)]))
        }
    }

    /// 一行 NDJSON(含結尾換行)。
    var line: Data {
        let json: String
        switch self {
        case .bytes(let data):
            json = #"{"type":"terminal.input","bytes":"\#(data.base64EncodedString())"}"#
        case .resize(let columns, let rows):
            json = #"{"type":"terminal.resize","cols":\#(columns),"rows":\#(rows),"cell_width_px":0,"cell_height_px":0}"#
        case .scroll(let direction, let lines, let column, let row):
            json = #"{"type":"terminal.scroll","direction":"\#(direction.rawValue)","lines":\#(lines),"source":"wheel","column":\#(column),"row":\#(row),"modifiers":0}"#
        case .release:
            json = #"{"type":"terminal.release"}"#
        }
        return Data(json.utf8) + [0x0A]
    }
}

// MARK: - wire format

/// stdout 的一行。不認得的訊息回傳 `nil`(herdr 文件:其他伺服器訊息丟棄)。
private enum TerminalStreamLine {
    case frame(TerminalFrame)
    case closed(TerminalCloseReason)

    init?(_ line: Data) {
        guard let wire = try? JSONDecoder().decode(WireMessage.self, from: line) else { return nil }
        switch wire.type {
        case "terminal.frame":
            guard let seq = wire.seq, let width = wire.width, let height = wire.height,
                  let base64 = wire.bytes, let bytes = Data(base64Encoded: base64) else { return nil }
            self = .frame(TerminalFrame(seq: seq, columns: width, rows: height, full: wire.full ?? false, bytes: bytes))
        case "terminal.closed":
            self = .closed(TerminalCloseReason(herdr: wire.reason))
        default:
            return nil
        }
    }
}

private struct WireMessage: Decodable {
    var type: String
    var seq: UInt64?
    var width: Int?
    var height: Int?
    var full: Bool?
    var bytes: String?
    var reason: String?
}
