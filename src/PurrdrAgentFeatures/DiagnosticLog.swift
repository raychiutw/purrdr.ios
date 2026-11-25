import Foundation

// 診斷記錄檔(`hitch-log.jsonl`,JSON Lines;卡頓、閃退與 MetricKit 共用)的一筆、儲存介面、大小裁切與編碼。

/// 記錄檔的一筆。
public enum DiagnosticEntry: Equatable, Sendable {
    case hitch(HitchEvent)
    case scroll(ScrollSummary)
    case metrics(HitchMetricsDigest)
    /// 閃退(中止前寫下的例外原因,下次啟動轉成記錄)。一律記錄,不受卡頓開關影響。
    case crash(CrashRecord)
    /// MetricKit 在下次啟動交出的閃退報告。一律記錄。
    case crashReport(MetricKitCrashReport)
    /// 匯出檔開頭的一筆:匯出時間與目前的系統狀態。
    case meta(HitchSystemState, at: Date)
}

/// 記錄的儲存:`append` 不阻塞呼叫端(真正的實作在背景序列佇列寫檔)。
public protocol DiagnosticLogStoring: Sendable {
    func append(_ entries: [DiagnosticEntry])
    /// 準備好可分享的檔案(開頭加一筆 `meta`);沒有任何記錄時回 nil。
    func exportFile(meta: DiagnosticEntry?) async -> URL?
    func clear() async
}

/// 記錄檔的大小上限:丟最舊的整行。
public enum DiagnosticLogTrimmer {
    /// 預設上限約 1 MB。
    public static let defaultMaxBytes = 1_000_000

    /// 超過上限時丟最舊的行,降到上限的八成以下(避免每次寫入都重寫檔案);沒超過原樣回傳。每行算上換行符號。
    public static func trim(_ lines: [String], maxBytes: Int) -> [String] {
        let sizes = lines.map { $0.utf8.count + 1 }
        var total = sizes.reduce(0, +)
        guard total > maxBytes else { return lines }
        let target = Int(Double(maxBytes) * 0.8)
        var dropped = 0
        while total > target, dropped < lines.count {
            total -= sizes[dropped]
            dropped += 1
        }
        return Array(lines.dropFirst(dropped))
    }
}

/// JSON Lines 編碼:每筆一行,含 schema 版本 `v` 與種類 `kind`。
public enum DiagnosticLogEncoder {
    public static let schemaVersion = 1

    public static func line(_ entry: DiagnosticEntry) -> String {
        var object: [String: Any] = ["v": schemaVersion]
        switch entry {
        case .hitch(let event):
            object["kind"] = "hitch"
            object["t"] = time(event.timestamp)
            object["ms"] = event.milliseconds
            object["frames"] = event.frames
            object["dropped"] = event.droppedFrames
            object["scroll"] = event.scroll.rawValue
            object["offsetY"] = event.offsetY
            object["velocityY"] = event.velocityY
            object["cells"] = event.visibleCells
            object["applies"] = event.activity.batchApplies
            object["fits"] = event.activity.fitCount
            object["fitMs"] = round1(event.activity.fitMilliseconds)
            object["offsetFixes"] = event.activity.offsetCorrections
            object["offsetFixPts"] = round1(event.activity.offsetCorrectionPoints)
            object["sizeChanges"] = event.activity.contentSizeChanges
            object["sizePts"] = round1(event.activity.contentSizeChangePoints)
            object["reconfigures"] = event.activity.reconfigures
            object["contentUpdates"] = event.activity.contentUpdates
            object["olderLoading"] = event.olderLoading
            object["working"] = event.agentWorking
            addSystem(event.system, to: &object, full: true)
        case .scroll(let summary):
            object["kind"] = "scroll"
            object["t"] = time(summary.timestamp)
            object["seconds"] = round3(summary.seconds)
            object["frames"] = summary.frames
            object["avgMs"] = summary.averageIntervalMilliseconds
            object["maxMs"] = summary.maxIntervalMilliseconds
            object["hitches"] = summary.hitchEvents
            object["hitchMs"] = summary.hitchMilliseconds
            object["hitchRatio"] = round3(summary.hitchTimeRatio)
            object["working"] = summary.agentWorking
            addSystem(summary.system, to: &object, full: false)
        case .metrics(let digest):
            object["kind"] = "metrics"
            object["t"] = time(digest.periodEnd)
            object["periodStart"] = time(digest.periodStart)
            object["periodEnd"] = time(digest.periodEnd)
            if let ratio = digest.scrollHitchTimeRatio { object["scrollHitchTimeRatio"] = round3(ratio) }
            object["hangs"] = digest.hangCount
            object["longestHangSeconds"] = round1(digest.longestHangSeconds)
            object["app"] = digest.app
            object["os"] = digest.os
        case .crash(let record):
            object["kind"] = "crash"
            object["t"] = time(record.timestamp)
            object["name"] = record.name
            object["reason"] = record.reason
            object["app"] = record.app
            object["os"] = record.os
            object["device"] = record.device
        case .crashReport(let report):
            object["kind"] = "crashReport"
            object["t"] = time(report.timestamp)
            if let value = report.exceptionType { object["exceptionType"] = value }
            if let value = report.signal { object["signal"] = value }
            if let value = report.terminationReason { object["terminationReason"] = value }
            if let value = report.exceptionName { object["name"] = value }
            if let value = report.exceptionReason { object["reason"] = value }
            object["frames"] = report.frames
            object["app"] = report.app
            object["os"] = report.os
            object["device"] = report.device
        case .meta(let system, let date):
            object["kind"] = "meta"
            object["t"] = time(date)
            addSystem(system, to: &object, full: true)
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func addSystem(_ system: HitchSystemState, to object: inout [String: Any], full: Bool) {
        object["thermal"] = system.thermal
        object["lowPower"] = system.lowPower
        object["device"] = system.device
        object["os"] = system.os
        object["app"] = system.app
        if full {
            object["reduceTransparency"] = system.reduceTransparency
            object["reduceMotion"] = system.reduceMotion
            object["textSize"] = system.textSize
            object["maxFps"] = system.maxFramesPerSecond
        }
    }

    private static func time(_ date: Date) -> String { date.formatted(.iso8601) }
    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
