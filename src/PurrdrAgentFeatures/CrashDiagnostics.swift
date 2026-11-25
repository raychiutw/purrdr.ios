import Foundation

// 閃退診斷(診斷記錄的一種):app 因 Objective-C 未捕捉例外中止前,同步寫一個很小的「待處理閃退」標記;
// 下次啟動把標記轉成一筆閃退記錄並刪除標記。只記例外名稱與原因字串,不含使用者內容。

/// 一筆閃退記錄。
public struct CrashRecord: Equatable, Sendable, Codable {
    public var timestamp: Date
    public var name: String
    public var reason: String
    public var app: String
    public var os: String
    public var device: String
    /// 只有 MetricKit 報告才有:整份 payload 涵蓋的時間區間(`timestamp` 是區間尾端,不是閃退的時間)。
    public var reportPeriod: ClosedRange<Date>?
    /// `name` 是不是真的例外名稱(MetricKit 的 Swift 執行期錯誤沒有例外名稱,`name` 只是備用文字)。
    public var nameIsKnown: Bool

    public init(
        timestamp: Date, name: String, reason: String, app: String, os: String, device: String,
        reportPeriod: ClosedRange<Date>? = nil, nameIsKnown: Bool = true
    ) {
        self.timestamp = timestamp
        self.name = name
        self.reason = reason
        self.app = app
        self.os = os
        self.device = device
        self.reportPeriod = reportPeriod
        self.nameIsKnown = nameIsKnown
    }

    /// 是不是同一次閃退:中止前標記是一個時間點;MetricKit 報告是一段區間,
    /// 區間內有同 app 版本、(有例外名稱時)同例外名稱的記錄就算同一次。
    func isSameCrash(as other: CrashRecord) -> Bool {
        guard app == other.app else { return false }
        if let period = reportPeriod {
            return period.contains(other.timestamp) && (!nameIsKnown || name == other.name)
        }
        if let period = other.reportPeriod {
            return period.contains(timestamp) && (!other.nameIsKnown || name == other.name)
        }
        return timestamp == other.timestamp && name == other.name
    }
}

/// 待處理閃退標記的儲存(注入的寫檔器;`write` 在中止前的處理器裡呼叫,必須同步且最小)。
public protocol CrashMarkerStoring: Sendable {
    func write(_ data: Data)
    func read() -> Data?
    func remove()
}

public final class CrashReporter: Sendable {
    /// 原因字串的長度上限(標記保持很小)。
    public static let maxReasonLength = 1_000

    private let store: any CrashMarkerStoring
    private let app: String
    private let os: String
    private let device: String
    private let clock: @Sendable () -> Date

    /// `app`、`os`、`device` 在安裝時先算好(中止前的處理器裡不做多餘的工作)。
    public init(
        store: any CrashMarkerStoring, app: String, os: String, device: String,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.app = app
        self.os = os
        self.device = device
        self.clock = clock
    }

    /// 例外處理器呼叫:中止前同步寫標記。
    public func exceptionWillTerminate(name: String, reason: String?) {
        let object: [String: Any] = [
            "name": String(name.prefix(200)),
            "reason": String((reason ?? "").prefix(Self.maxReasonLength)),
            "t": clock().timeIntervalSince1970,
            "app": app, "os": os, "device": device,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        store.write(data)
    }

    /// 啟動時呼叫:有待處理的標記就轉成一筆閃退記錄(一律記,不看卡頓開關)並刪除標記;壞掉的標記直接丟掉。
    @MainActor
    public func recoverPending(into recorder: DiagnosticRecorder) {
        guard let data = store.read() else { return }
        store.remove()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = object["name"] as? String, let seconds = object["t"] as? Double
        else { return }
        recorder.recordCrash(CrashRecord(
            timestamp: Date(timeIntervalSince1970: seconds), name: name, reason: object["reason"] as? String ?? "",
            app: object["app"] as? String ?? "?", os: object["os"] as? String ?? "?", device: object["device"] as? String ?? "?"))
    }
}
