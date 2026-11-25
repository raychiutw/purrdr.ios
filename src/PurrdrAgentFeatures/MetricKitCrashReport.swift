import Foundation

// MetricKit 的閃退診斷(下次啟動由系統交出):從 `MXDiagnosticPayload.jsonRepresentation()` 取出
// 錯誤類型、訊號、終止原因、Objective-C 例外、被歸責執行緒的呼叫堆疊(二進位 UUID＋位移,供 dSYM 符號化)。
// 只處理 JSON,不碰 MetricKit 型別,所以可在 `swift test` 以 fixture 驗證。不含對話內容、主機位址、權杖或檔案內容。

/// 一筆來自 MetricKit 的閃退報告。`app`／`os` 的格式與 `CrashRecord`(中止前的標記)相同,
/// 兩者以時間與版本對得上同一次閃退。
public struct MetricKitCrashReport: Equatable, Sendable {
    public var timestamp: Date
    public var exceptionType: Int?
    public var signal: Int?
    public var terminationReason: String?
    public var exceptionName: String?
    public var exceptionReason: String?
    /// 被歸責執行緒的呼叫堆疊,由外往內,每列 `二進位名稱 UUID +位移`。
    public var frames: [String]
    public var environment: DiagnosticEnvironment
    /// payload 時間區間的開頭(`timestamp` 是尾端)。
    public var periodStart: Date?

    public init(
        timestamp: Date, exceptionType: Int?, signal: Int?, terminationReason: String?, exceptionName: String?,
        exceptionReason: String?, frames: [String], environment: DiagnosticEnvironment, periodStart: Date? = nil
    ) {
        self.timestamp = timestamp
        self.exceptionType = exceptionType
        self.signal = signal
        self.terminationReason = terminationReason
        self.exceptionName = exceptionName
        self.exceptionReason = exceptionReason
        self.frames = frames
        self.environment = environment
        self.periodStart = periodStart
    }

    /// 去重用的鍵:報告時間與內容(類型、訊號、例外、堆疊)。
    var dedupKey: String {
        let content = [
            "\(exceptionType ?? -1)", "\(signal ?? -1)", terminationReason ?? "", exceptionName ?? "", exceptionReason ?? "",
            frames.joined(separator: "|"),
        ].joined(separator: "\u{1}")
        return "\(Int(timestamp.timeIntervalSince1970))-\(Self.fnv1a(content))"
    }

    /// 穩定的雜湊(`hashValue` 每次啟動不同,不能跨重啟比對)。
    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

public enum MetricKitCrashParser {
    /// 呼叫堆疊最多留幾列(記錄不無限長大)。
    public static let maxFrames = 40
    public static let maxTextLength = 1_000

    public static func parse(payloadJSON: Data) -> [MetricKitCrashReport] {
        guard let root = try? JSONSerialization.jsonObject(with: payloadJSON) as? [String: Any],
            let diagnostics = root["crashDiagnostics"] as? [[String: Any]]
        else { return [] }
        let timestamp = date(root["timeStampEnd"]) ?? date(root["timeStampBegin"]) ?? Date(timeIntervalSince1970: 0)
        let start = date(root["timeStampBegin"])
        return diagnostics.map { report(from: $0, timestamp: timestamp, periodStart: start) }
    }

    private static func report(from diagnostic: [String: Any], timestamp: Date, periodStart: Date?) -> MetricKitCrashReport {
        let meta = diagnostic["diagnosticMetaData"] as? [String: Any] ?? [:]
        let objc = meta["objectiveCexceptionReason"] as? [String: Any]
        let version = meta["appVersion"] as? String ?? "?"
        let build = meta["appBuildVersion"] as? String ?? "?"
        return MetricKitCrashReport(
            timestamp: timestamp,
            exceptionType: meta["exceptionType"] as? Int,
            signal: meta["signal"] as? Int,
            terminationReason: text(meta["terminationReason"]),
            exceptionName: text(objc?["exceptionName"]),
            exceptionReason: text(objc?["composedMessage"] ?? objc?["message"]),
            frames: frames(from: diagnostic["callStackTree"] as? [String: Any]),
            environment: DiagnosticEnvironment(
                app: "\(version) (\(build))", os: os(meta["osVersion"] as? String), device: meta["deviceType"] as? String ?? "?"),
            periodStart: periodStart)
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return String(string.prefix(maxTextLength))
    }

    /// "iPhone OS 27.0.1 (24A100)" → "iOS 27.0.1"(與標記檔記錄同格式)。
    private static func os(_ raw: String?) -> String {
        guard let raw else { return "?" }
        let base = raw.split(separator: "(").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? raw
        return base.hasPrefix("iPhone OS ") ? "iOS " + base.dropFirst("iPhone OS ".count) : base
    }

    private static func frames(from tree: [String: Any]?) -> [String] {
        let stacks = tree?["callStacks"] as? [[String: Any]] ?? []
        guard let attributed = stacks.first(where: { $0["threadAttributed"] as? Bool == true }) else { return [] }
        var lines: [String] = []
        var level = attributed["callStackRootFrames"] as? [[String: Any]] ?? []
        // 每層取第一個子 frame 往內走(MetricKit 的樹在閃退執行緒上是一條鏈)。
        while let frame = level.first, lines.count < maxFrames {
            let name = frame["binaryName"] as? String ?? "?"
            let uuid = frame["binaryUUID"] as? String ?? "?"
            let offset = (frame["offsetIntoBinaryTextSegment"] as? Int) ?? 0
            lines.append("\(name) \(uuid) +\(offset)")
            level = frame["subFrames"] as? [[String: Any]] ?? []
        }
        return lines
    }

    /// MetricKit 的時間字串是 UTC 的 `yyyy-MM-dd HH:mm:ss`;也容忍 ISO 8601。
    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: string) { return date }
        return try? Date(string, strategy: .iso8601)
    }
}

/// 把 MetricKit 的閃退報告寫進診斷記錄(一律記,不看卡頓開關),並以「報告時間＋內容」去重。
/// 已記過的鍵存在 `defaults`(最近 50 筆),MetricKit 重送或 app 重啟後再收到也不重複。
@MainActor
public final class MetricKitCrashIntake {
    static let seenKey = "diagnostics.metricKitCrashSeen"
    static let maxSeen = 50

    private let recorder: DiagnosticRecorder
    private let defaults: UserDefaults

    public init(recorder: DiagnosticRecorder, defaults: UserDefaults = .standard) {
        self.recorder = recorder
        self.defaults = defaults
    }

    public func ingest(payloadJSON: Data) {
        var seen = defaults.stringArray(forKey: Self.seenKey) ?? []
        for report in MetricKitCrashParser.parse(payloadJSON: payloadJSON) {
            let key = report.dedupKey
            guard !seen.contains(key) else { continue }
            seen.append(key)
            recorder.recordCrashReport(report)
        }
        defaults.set(Array(seen.suffix(Self.maxSeen)), forKey: Self.seenKey)
    }
}
