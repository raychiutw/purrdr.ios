import Foundation
import Testing
@testable import PurrdrAgentFeatures

/// fixture 依 Apple 文件的 MXDiagnosticPayload／MXHangDiagnostic `jsonRepresentation()` 形狀手寫
/// (沒有真實裝置樣本;二進位 UUID 與位址為編造,不含個人資料)。
/// TODO: 第一份 TestFlight 真實卡頓報告回來後,以真實 payload 取代(或補上)這裡的 fixture。
enum MetricKitHangFixtures {
    /// 兩次卡頓:2.5 秒與 7 秒(後者的堆疊要留下);堆疊樹在主執行緒分叉,取樣最多的那一支才是卡住的地方。
    static let twoHangs = Data("""
    {"timeStampBegin":"2026-11-24 08:00:00","timeStampEnd":"2026-11-25 08:00:00",
     "hangDiagnostics":[
      {"version":"1.0.0","diagnosticMetaData":{"appBuildVersion":"7","appVersion":"0.55.0","deviceType":"iPhone18,1",
        "osVersion":"iPhone OS 27.0.1 (24A100)","hangDuration":"2500 ms"},
       "callStackTree":{"callStackPerThread":false,"callStacks":[{"callStackRootFrames":[
         {"binaryUUID":"11111111-2222-3333-4444-555555555555","offsetIntoBinaryTextSegment":1,"sampleCount":2,"binaryName":"UIKitCore"}]}]}},
      {"version":"1.0.0","diagnosticMetaData":{"appBuildVersion":"7","appVersion":"0.55.0","deviceType":"iPhone18,1",
        "osVersion":"iPhone OS 27.0.1 (24A100)","hangDuration":"7 sec"},
       "callStackTree":{"callStackPerThread":false,"callStacks":[{"callStackRootFrames":[
         {"binaryUUID":"AAAAAAAA-0000-0000-0000-000000000001","offsetIntoBinaryTextSegment":10,"sampleCount":9,"binaryName":"dyld",
          "subFrames":[
            {"binaryUUID":"BBBBBBBB-0000-0000-0000-000000000002","offsetIntoBinaryTextSegment":20,"sampleCount":1,"binaryName":"libsystem"},
            {"binaryUUID":"66666666-7777-8888-9999-000000000000","offsetIntoBinaryTextSegment":512,"sampleCount":8,"binaryName":"Purrdr"}]}]}]}}]}
    """.utf8)

    static let noHang = Data(#"{"timeStampEnd":"2026-11-25 08:00:00","crashDiagnostics":[{}]}"#.utf8)
}

@Suite("診斷記錄:MetricKit 卡頓報告")
struct MetricKitHangReportTests {
    @Test("次數、最長秒數與主執行緒堆疊(取樣最多的那一支,只有 binary 與 offset)")
    func countLongestAndStack() throws {
        let report = try #require(MetricKitHangParser.parse(payloadJSON: MetricKitHangFixtures.twoHangs))
        #expect(report.count == 2)
        #expect(report.longestSeconds == 7)
        #expect(report.frames == [
            "dyld AAAAAAAA-0000-0000-0000-000000000001 +10",
            "Purrdr 66666666-7777-8888-9999-000000000000 +512",
        ])
        #expect(report.environment.app == "0.55.0 (7)")
        #expect(report.environment.os == "iOS 27.0.1")
        #expect(report.timestamp == Date(timeIntervalSince1970: 1_795_593_600))
    }

    @Test("沒有卡頓診斷或不是 JSON:回 nil")
    func nothingToParse() {
        #expect(MetricKitHangParser.parse(payloadJSON: MetricKitHangFixtures.noHang) == nil)
        #expect(MetricKitHangParser.parse(payloadJSON: Data("nope".utf8)) == nil)
    }

    @Test("呼叫堆疊深度有上限")
    func framesAreCapped() throws {
        var frame = #"{"binaryUUID":"U","offsetIntoBinaryTextSegment":1,"binaryName":"B"}"#
        for _ in 0..<100 { frame = #"{"binaryUUID":"U","offsetIntoBinaryTextSegment":1,"binaryName":"B","subFrames":[\#(frame)]}"# }
        let json = Data(#"{"timeStampEnd":"2026-11-25 08:00:00","hangDiagnostics":[{"diagnosticMetaData":{"hangDuration":"3 sec"},"callStackTree":{"callStacks":[{"callStackRootFrames":[\#(frame)]}]}}]}"#.utf8)
        let report = try #require(MetricKitHangParser.parse(payloadJSON: json))
        #expect(report.frames.count == MetricKitCrashParser.maxFrames)
    }

    @Test("卡頓時間的各種寫法:毫秒、秒、數字")
    func durationFormats() {
        #expect(MetricKitHangParser.seconds(from: "2500 ms") == 2.5)
        #expect(MetricKitHangParser.seconds(from: "7 sec") == 7)
        #expect(MetricKitHangParser.seconds(from: "1,250 ms") == 1.25)
        #expect(MetricKitHangParser.seconds(from: 4.5) == 4.5)
        #expect(MetricKitHangParser.seconds(from: "?") == nil)
    }

    @MainActor
    @Test("一律寫進診斷記錄(不看操作記錄開關),重複送來只記一次")
    func recordsAlwaysAndDeduplicates() throws {
        let sink = RecordingDiagnosticSink()
        let defaults = UserDefaults(suiteName: "mkhang-\(UUID().uuidString)")!
        let recorder = DiagnosticRecorder(sink: sink, defaults: defaults, system: { .sample }, wallClock: { Date() })
        recorder.isEnabled = false
        let seen = InMemoryMetricKitCrashSeenStore()
        MetricKitHangIntake(recorder: recorder, seen: seen).ingest(payloadJSON: MetricKitHangFixtures.twoHangs)
        MetricKitHangIntake(recorder: recorder, seen: seen).ingest(payloadJSON: MetricKitHangFixtures.twoHangs)
        let hangs = sink.entries.compactMap { entry -> MetricKitHangReport? in
            if case .hangReport(let report) = entry { report } else { nil }
        }
        #expect(hangs.count == 1)
    }

    @Test("匯出的一行 JSON:次數、最長秒數與堆疊")
    func encodesLine() throws {
        let report = try #require(MetricKitHangParser.parse(payloadJSON: MetricKitHangFixtures.twoHangs))
        let line = DiagnosticLogEncoder.line(.hangReport(report))
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "hangReport")
        #expect(object["hangs"] as? Int == 2)
        #expect(object["longestHangSeconds"] as? Double == 7)
        #expect((object["frames"] as? [String])?.count == 2)
        #expect(object["app"] as? String == "0.55.0 (7)")
    }

    @Test("MetricKit 指標的卡頓直方圖:次數是各區間總和,最長取最大區間的上界;沒有區間是 0")
    func histogramSummary() {
        let summary = HangHistogramSummary(buckets: [(start: 0, end: 1, count: 3), (start: 1, end: 4, count: 2), (start: 4, end: 9, count: 0)])
        #expect(summary.count == 5)
        #expect(summary.longestSeconds == 4)
        let empty = HangHistogramSummary(buckets: [])
        #expect(empty.count == 0)
        #expect(empty.longestSeconds == 0)
    }
}
