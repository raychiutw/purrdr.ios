import Foundation

// MetricKit 的卡頓診斷(`MXDiagnosticPayload.hangDiagnostics`,#690):保留主執行緒的呼叫堆疊,
// 沿用閃退報告的堆疊解析——最多 40 列,只記 binary 名稱、UUID 與位移,不含任何內容。
// 只處理 JSON,不碰 MetricKit 型別,所以可在 `swift test` 以 fixture 驗證。

/// 一份 payload 裡的卡頓報告:次數、最長秒數,以及最長那次的主執行緒堆疊。
public struct MetricKitHangReport: Equatable, Sendable {
    /// payload 時間區間的尾端。
    public var timestamp: Date
    public var count: Int
    public var longestSeconds: Double
    /// 最長那次卡頓的主執行緒呼叫堆疊,由外往內,每列 `二進位名稱 UUID +位移`。
    public var frames: [String]
    public var environment: DiagnosticEnvironment

    public init(timestamp: Date, count: Int, longestSeconds: Double, frames: [String], environment: DiagnosticEnvironment) {
        self.timestamp = timestamp
        self.count = count
        self.longestSeconds = longestSeconds
        self.frames = frames
        self.environment = environment
    }

    /// 去重用的鍵:報告時間與內容。
    var dedupKey: String {
        let content = ["\(count)", "\(longestSeconds)", frames.joined(separator: "|")].joined(separator: "\u{1}")
        return "hang-\(Int(timestamp.timeIntervalSince1970))-\(MetricKitCrashReport.fnv1a(content))"
    }
}

/// `MXMetricPayload` 的卡頓時間直方圖(`histogrammedApplicationHangTime`)摘要:
/// 次數是各區間筆數的總和,最長取有筆數的區間裡最大的上界。
public struct HangHistogramSummary: Equatable, Sendable {
    public var count: Int
    public var longestSeconds: Double

    public init(buckets: [(start: Double, end: Double, count: Int)]) {
        let used = buckets.filter { $0.count > 0 }
        count = used.map(\.count).reduce(0, +)
        longestSeconds = used.map(\.end).max() ?? 0
    }
}

public enum MetricKitHangParser {
    /// 一份 payload 的卡頓診斷彙整成一筆;沒有卡頓診斷(或不是 JSON)回 `nil`。
    public static func parse(payloadJSON: Data) -> MetricKitHangReport? {
        guard let root = try? JSONSerialization.jsonObject(with: payloadJSON) as? [String: Any],
            let diagnostics = root["hangDiagnostics"] as? [[String: Any]], !diagnostics.isEmpty
        else { return nil }
        let timestamp = MetricKitCrashParser.date(root["timeStampEnd"]) ?? MetricKitCrashParser.date(root["timeStampBegin"])
            ?? Date(timeIntervalSince1970: 0)
        let durations = diagnostics.map { seconds(from: ($0["diagnosticMetaData"] as? [String: Any])?["hangDuration"]) ?? 0 }
        let longestIndex = durations.indices.max { durations[$0] < durations[$1] } ?? 0
        let longest = diagnostics[longestIndex]
        let meta = longest["diagnosticMetaData"] as? [String: Any] ?? [:]
        let version = meta["appVersion"] as? String ?? "?"
        let build = meta["appBuildVersion"] as? String ?? "?"
        return MetricKitHangReport(
            timestamp: timestamp, count: diagnostics.count, longestSeconds: durations[longestIndex],
            frames: MetricKitCrashParser.frames(from: longest["callStackTree"] as? [String: Any], requiresAttribution: false),
            environment: DiagnosticEnvironment(
                app: "\(version) (\(build))", os: MetricKitCrashParser.os(meta["osVersion"] as? String),
                device: meta["deviceType"] as? String ?? "?"))
    }

    /// 卡頓時間:數字(秒)或 "2500 ms"／"7 sec"／"1,250 ms" 這類字串;讀不懂回 `nil`。
    static func seconds(from value: Any?) -> Double? {
        if let number = value as? Double { return number }
        guard let text = value as? String else { return nil }
        let parts = text.replacingOccurrences(of: ",", with: "").split(separator: " ")
        guard let first = parts.first, let number = Double(first) else { return nil }
        switch parts.dropFirst().first.map({ $0.lowercased() }) {
        case "ms", "msec", "msecs": return number / 1_000
        case "s", "sec", "secs", "second", "seconds", nil: return number
        default: return nil
        }
    }
}

/// 把 MetricKit 的卡頓報告寫進診斷記錄(一律記,不看操作記錄開關,比照閃退),以「報告時間＋內容」去重。
@MainActor
public final class MetricKitHangIntake {
    private let recorder: DiagnosticRecorder
    private let seen: any MetricKitCrashSeenStoring

    public init(recorder: DiagnosticRecorder, seen: any MetricKitCrashSeenStoring = UserDefaultsMetricKitCrashSeenStore(key: "diagnostics.metricKitHangSeen")) {
        self.recorder = recorder
        self.seen = seen
    }

    public func ingest(payloadJSON: Data) {
        guard let report = MetricKitHangParser.parse(payloadJSON: payloadJSON) else { return }
        var keys = seen.keys
        guard !keys.contains(report.dedupKey) else { return }
        keys.append(report.dedupKey)
        seen.keys = Array(keys.suffix(MetricKitCrashIntake.maxSeen))
        recorder.recordHangReport(report)
    }
}
