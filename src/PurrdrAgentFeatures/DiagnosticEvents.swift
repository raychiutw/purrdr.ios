import CryptoKit
import Foundation
import Synchronization
import os

// 診斷事件(#688、spec #679):型別化的連線事件,只有兩個出口——
// 系統 Console(固定文字公開、主機位址與動態內容私密)與可分享的診斷檔(只有類別、代碼、主機匿名序號)。
// 事件可能從 NIO event loop 的回呼鏈上送來:`record` 只做擷取與排程,組字串、查序號、寫檔都在內部背景序列佇列(AGENTS.md #470)。

/// 連線為什麼結束(診斷代碼,與 SSH 的 `SSHDropReason` 一一對應;核心以外的模組不依賴 SSH)。
public enum DiagnosticDropReason: String, Sendable, Equatable {
    case keepaliveTimeout = "keepalive_timeout"
    case channelOpenTimeout = "channel_open_timeout"
    case disconnectRequested = "disconnect_requested"
    case networkError = "network_error"
    case closedByPeer = "closed_by_peer"

    var consoleText: String {
        switch self {
        case .keepaliveTimeout: "keepalive timeout"
        case .channelOpenTimeout: "channel open timeout"
        case .disconnectRequested: "disconnect requested by the app"
        case .networkError: "network error"
        case .closedByPeer: "closed by the host or the network"
        }
    }
}

/// 一個診斷事件。`host` 是主機位址(只給 Console 用、標 private;診斷檔只寫匿名序號),`detail` 是動態描述(只給 Console、標 private)。
public enum DiagnosticEvent: Sendable, Equatable {
    case connected(host: String, dial: Int)
    /// `error` 只能是錯誤種類名稱(不含關聯值)。
    case dialFailed(host: String, dial: Int, error: String, detail: String)
    case dropped(host: String, dial: Int, reason: DiagnosticDropReason, lifetimeSeconds: Int, detail: String?)
    case networkChanged(droppedConnections: Int, detail: String)
    /// 回前景時連線沿用還是重撥。
    case foregroundDecision(backgroundSeconds: Int, redial: Bool)
    /// 會員流程結果碼(`code` 是固定代碼,`detail` 是後台回傳的動態內容)。
    case member(code: String, detail: String?)

    /// Console 的 category(Console.app 以 subsystem `com.raychiu.purrdr` 篩選)。
    public var consoleCategory: String {
        switch self {
        case .connected, .dialFailed, .dropped: "ssh"
        case .networkChanged, .foregroundDecision: "hosts"
        case .member: "member"
        }
    }

    public var host: String? {
        switch self {
        case .connected(let host, _), .dialFailed(let host, _, _, _), .dropped(let host, _, _, _, _): host
        case .networkChanged, .foregroundDecision, .member: nil
        }
    }

    /// 固定文字(不含動態內容),Console 以 public 記錄。
    public var consoleFixedText: String {
        switch self {
        case .connected(_, let dial): "dial \(dial) connected"
        case .dialFailed(_, let dial, let error, _): "dial \(dial) failed: \(error)"
        case .dropped(_, let dial, let reason, let lifetime, _): "dial \(dial) dropped after \(lifetime)s: \(reason.consoleText)"
        case .networkChanged(let count, _): "Network path changed: dropping \(count) host connection(s)"
        case .foregroundDecision(let seconds, let redial): "foreground after \(seconds)s: \(redial ? "redial" : "reuse")"
        case .member(let code, _): code
        }
    }

    /// 動態內容(Console 以 private 記錄)。
    public var consoleDetail: String? {
        switch self {
        case .connected, .foregroundDecision: nil
        case .dialFailed(_, _, _, let detail): detail
        case .dropped(_, _, _, _, let detail): detail
        case .networkChanged(_, let detail): detail
        case .member(_, let detail): detail
        }
    }

    /// 固定文字加動態內容(測試與人讀用)。
    public var consoleText: String {
        guard let detail = consoleDetail, !detail.isEmpty else { return consoleFixedText }
        if case .dialFailed = self { return consoleFixedText }
        return "\(consoleFixedText): \(detail)"
    }
}

/// 診斷檔裡的一筆事件:沒有主機位址與動態描述,只有類別、代碼、原因代碼、主機匿名序號與數值。
public struct DiagnosticEventRecord: Equatable, Sendable {
    public var at: Date
    public var category: String
    public var code: String
    public var reason: String?
    /// 主機在這份檔案裡的匿名序號(「主機 2」的 2)。
    public var host: Int?
    public var dial: Int?
    /// 事件的數值:中斷時是連線壽命秒數、網路切換是丟棄的連線數、回前景是背景秒數。
    public var value: Int?

    public init(at: Date, category: String, code: String, reason: String? = nil, host: Int? = nil, dial: Int? = nil, value: Int? = nil) {
        self.at = at
        self.category = category
        self.code = code
        self.reason = reason
        self.host = host
        self.dial = dial
        self.value = value
    }
}

/// 主機位址 → 匿名序號(從 1 起,同一份檔案內固定)。位址只以雜湊存放。
public final class HostOrdinals: Sendable {
    private let state: Mutex<[String: Int]>
    private let persist: @Sendable ([String: Int]) -> Void

    public init(initial: [String: Int] = [:], persist: @escaping @Sendable ([String: Int]) -> Void = { _ in }) {
        state = Mutex(initial)
        self.persist = persist
    }

    public func ordinal(for host: String) -> Int {
        let key = DiagnosticHash.reason(host)
        let (value, changed, snapshot) = state.withLock { map -> (Int, Bool, [String: Int]) in
            if let existing = map[key] { return (existing, false, map) }
            let next = (map.values.max() ?? 0) + 1
            map[key] = next
            return (next, true, map)
        }
        if changed { persist(snapshot) }
        return value
    }

    /// 存在 `UserDefaults` 的對應表(只有位址雜湊與序號)。
    public static func userDefaults(_ defaults: UserDefaults, key: String = "diagnostics.hostOrdinals") -> HostOrdinals {
        nonisolated(unsafe) let defaults = defaults
        return HostOrdinals(initial: defaults.dictionary(forKey: key) as? [String: Int] ?? [:]) { map in defaults.set(map, forKey: key) }
    }
}

/// 診斷用的穩定雜湊(SHA-256 前 8 bytes 的十六進位,16 字元)。
public enum DiagnosticHash {
    /// 閃退原因等不能留原文的字串。
    public static func reason(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// 診斷事件的入口。任何執行緒都能呼叫 `record`;Console 一律記,診斷檔只在「操作記錄」開著時寫。
public final class DiagnosticEvents: Sendable {
    private let sink: (any DiagnosticLogStoring)?
    private let isEnabled: @Sendable () -> Bool
    private let console: @Sendable (DiagnosticEvent) -> Void
    private let ordinals: HostOrdinals
    private let clock: @Sendable () -> Date
    private let queue = DispatchQueue(label: "purrdr.diagnostic-events", qos: .utility)

    public init(
        sink: (any DiagnosticLogStoring)?, isEnabled: @escaping @Sendable () -> Bool,
        console: @escaping @Sendable (DiagnosticEvent) -> Void = DiagnosticEvents.systemConsole,
        ordinals: HostOrdinals = HostOrdinals(), clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sink = sink
        self.isEnabled = isEnabled
        self.console = console
        self.ordinals = ordinals
        self.clock = clock
    }

    /// 不記錄的實作(測試、UI 測試)。
    public static let discarding = DiagnosticEvents(sink: nil, isEnabled: { false }, console: { _ in })

    public func record(_ event: DiagnosticEvent) {
        let at = clock()
        queue.async { [self] in
            console(event)
            guard isEnabled(), let sink else { return }
            sink.append([.event(Self.record(for: event, at: at, ordinals: ordinals))])
        }
    }

    /// 等排進佇列的事件都處理完(測試與離開前用)。
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    static func record(for event: DiagnosticEvent, at: Date, ordinals: HostOrdinals) -> DiagnosticEventRecord {
        let category = event.consoleCategory
        let host = event.host.map(ordinals.ordinal(for:))
        switch event {
        case .connected(_, let dial):
            return DiagnosticEventRecord(at: at, category: category, code: "connected", host: host, dial: dial)
        case .dialFailed(_, let dial, let error, _):
            return DiagnosticEventRecord(at: at, category: category, code: "dial_failed", reason: error, host: host, dial: dial)
        case .dropped(_, let dial, let reason, let lifetime, _):
            return DiagnosticEventRecord(at: at, category: category, code: "dropped", reason: reason.rawValue, host: host, dial: dial, value: lifetime)
        case .networkChanged(let count, _):
            return DiagnosticEventRecord(at: at, category: category, code: "network_changed", value: count)
        case .foregroundDecision(let seconds, let redial):
            return DiagnosticEventRecord(at: at, category: category, code: "foreground", reason: redial ? "redial" : "reuse", value: seconds)
        case .member(let code, _):
            return DiagnosticEventRecord(at: at, category: category, code: code)
        }
    }

    /// 系統 Console(`os.Logger`):固定文字 public,主機位址與動態內容 private。
    public static let systemConsole: @Sendable (DiagnosticEvent) -> Void = { event in
        let logger = Logger(subsystem: "com.raychiu.purrdr", category: event.consoleCategory)
        let text = event.consoleFixedText
        let detail = event.consoleDetail ?? ""
        switch event {
        case .connected, .foregroundDecision, .member(_, nil):
            if let host = event.host {
                logger.notice("\(host, privacy: .private): \(text, privacy: .public)")
            } else {
                logger.notice("\(text, privacy: .public)")
            }
        default:
            if let host = event.host {
                logger.error("\(host, privacy: .private): \(text, privacy: .public) \(detail, privacy: .private)")
            } else {
                logger.error("\(text, privacy: .public) \(detail, privacy: .private)")
            }
        }
    }
}
