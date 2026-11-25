import Foundation
import Testing
@testable import PurrdrAgentFeatures

/// fixture 依 Apple 文件的 MXDiagnosticPayload／MXCrashDiagnostic `jsonRepresentation()` 形狀手寫
/// (沒有真實裝置樣本;欄位名稱照文件,二進位 UUID 與位址為編造,不含個人資料)。
enum MetricKitCrashFixtures {
    static let full = Data("""
    {"timeStampBegin":"2026-11-24 08:00:00","timeStampEnd":"2026-11-25 08:00:00",
     "crashDiagnostics":[{"version":"1.0.0",
       "diagnosticMetaData":{"appBuildVersion":"7","appVersion":"0.52.2","bundleIdentifier":"com.raychiu.purrdr",
         "deviceType":"iPhone18,1","exceptionCode":0,"exceptionType":6,"osVersion":"iPhone OS 27.0.1 (24A100)",
         "platformArchitecture":"arm64","signal":6,
         "terminationReason":"Namespace SIGNAL, Code 6 Abort trap: 6",
         "objectiveCexceptionReason":{"composedMessage":"invalid number of items in section 0","exceptionName":"NSInternalInconsistencyException","message":"invalid number of items in section %d","arguments":["0"]}},
       "callStackTree":{"callStackPerThread":true,"callStacks":[
         {"threadAttributed":false,"callStackRootFrames":[{"binaryUUID":"AAAAAAAA-0000-0000-0000-000000000001","offsetIntoBinaryTextSegment":10,"sampleCount":1,"binaryName":"libsystem","address":100}]},
         {"threadAttributed":true,"callStackRootFrames":[
           {"binaryUUID":"11111111-2222-3333-4444-555555555555","offsetIntoBinaryTextSegment":4096,"sampleCount":1,"binaryName":"UIKitCore","address":200,
            "subFrames":[{"binaryUUID":"66666666-7777-8888-9999-000000000000","offsetIntoBinaryTextSegment":512,"sampleCount":1,"binaryName":"Purrdr","address":300}]}]}]}}]}
    """.utf8)

    /// Swift 執行期錯誤:沒有 Objective-C 例外,也沒有 terminationReason 的例外段落。
    static let swiftRuntime = Data("""
    {"timeStampBegin":"2026-11-24 08:00:00","timeStampEnd":"2026-11-25 08:00:00",
     "crashDiagnostics":[{"version":"1.0.0",
       "diagnosticMetaData":{"appBuildVersion":"7","appVersion":"0.52.2","deviceType":"iPhone18,1","exceptionType":6,
         "osVersion":"iPhone OS 27.0.1 (24A100)","signal":4},
       "callStackTree":{"callStackPerThread":true,"callStacks":[]}}]}
    """.utf8)

    static let noCrash = Data(#"{"timeStampBegin":"2026-11-24 08:00:00","timeStampEnd":"2026-11-25 08:00:00","hangDiagnostics":[{}]}"#.utf8)
}

@Suite("診斷記錄:MetricKit 閃退報告")
struct MetricKitCrashReportTests {
    @Test("完整欄位:類型、訊號、終止原因、例外名稱與原因、呼叫堆疊、app 與 iOS 版本")
    func fullFields() throws {
        let reports = MetricKitCrashParser.parse(payloadJSON: MetricKitCrashFixtures.full)
        let report = try #require(reports.first)
        #expect(reports.count == 1)
        #expect(report.exceptionType == 6)
        #expect(report.signal == 6)
        #expect(report.terminationReason == "Namespace SIGNAL, Code 6 Abort trap: 6")
        #expect(report.exceptionName == "NSInternalInconsistencyException")
        #expect(report.exceptionReason == "invalid number of items in section 0")
        #expect(report.environment.app == "0.52.2 (7)")
        #expect(report.environment.os == "iOS 27.0.1")
        #expect(report.environment.device == "iPhone18,1")
        // 只取被歸責的執行緒,由外往內
        #expect(report.frames == [
            "UIKitCore 11111111-2222-3333-4444-555555555555 +4096",
            "Purrdr 66666666-7777-8888-9999-000000000000 +512",
        ])
        #expect(report.timestamp == Date(timeIntervalSince1970: 1_795_593_600))
    }

    @Test("缺欄位(Swift 執行期錯誤):沒有例外與堆疊也照樣記")
    func swiftRuntimeError() throws {
        let report = try #require(MetricKitCrashParser.parse(payloadJSON: MetricKitCrashFixtures.swiftRuntime).first)
        #expect(report.signal == 4)
        #expect(report.exceptionName == nil)
        #expect(report.exceptionReason == nil)
        #expect(report.terminationReason == nil)
        #expect(report.frames.isEmpty)
    }

    @Test("沒有閃退診斷或不是 JSON:回空")
    func nothingToParse() {
        #expect(MetricKitCrashParser.parse(payloadJSON: MetricKitCrashFixtures.noCrash).isEmpty)
        #expect(MetricKitCrashParser.parse(payloadJSON: Data("nope".utf8)).isEmpty)
    }

    @Test("呼叫堆疊深度有上限")
    func framesAreCapped() throws {
        var frame = #"{"binaryUUID":"U","offsetIntoBinaryTextSegment":1,"binaryName":"B"}"#
        for _ in 0..<100 { frame = #"{"binaryUUID":"U","offsetIntoBinaryTextSegment":1,"binaryName":"B","subFrames":[\#(frame)]}"# }
        let json = Data(#"{"timeStampEnd":"2026-11-25 08:00:00","crashDiagnostics":[{"diagnosticMetaData":{"signal":11},"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[\#(frame)]}]}}]}"#.utf8)
        let report = try #require(MetricKitCrashParser.parse(payloadJSON: json).first)
        #expect(report.frames.count == MetricKitCrashParser.maxFrames)
    }

    @MainActor
    @Test("轉成記錄:寫進診斷記錄,同一份報告重複送來只記一次(跨重啟)")
    func deduplicates() throws {
        let suite = "mkcrash-\(UUID().uuidString)"
        let sink = RecordingDiagnosticSink()
        let defaults = UserDefaults(suiteName: suite)!
        let recorder = DiagnosticRecorder(sink: sink, defaults: defaults, system: { .sample }, wallClock: { Date() })
        let first = MetricKitCrashIntake(recorder: recorder, defaults: defaults)
        first.ingest(payloadJSON: MetricKitCrashFixtures.full)
        first.ingest(payloadJSON: MetricKitCrashFixtures.full)
        // 重啟:新的 intake 讀同一份 defaults
        MetricKitCrashIntake(recorder: recorder, defaults: defaults).ingest(payloadJSON: MetricKitCrashFixtures.full)
        let crashes = sink.entries.compactMap { entry -> MetricKitCrashReport? in
            if case .crashReport(let report) = entry { report } else { nil }
        }
        #expect(crashes.count == 1)
        // 內容不同(訊號不同)就是另一次閃退
        first.ingest(payloadJSON: MetricKitCrashFixtures.swiftRuntime)
        #expect(sink.entries.count == 2)
    }

    @Test("匯出的一行 JSON 帶 kind、時間與版本,能與標記檔記錄對上")
    func encodesLine() throws {
        let report = try #require(MetricKitCrashParser.parse(payloadJSON: MetricKitCrashFixtures.full).first)
        let line = DiagnosticLogEncoder.line(.crashReport(report))
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "crashReport")
        #expect(object["app"] as? String == "0.52.2 (7)")
        #expect(object["os"] as? String == "iOS 27.0.1")
        #expect(object["signal"] as? Int == 6)
        #expect((object["frames"] as? [String])?.count == 2)
    }
}
