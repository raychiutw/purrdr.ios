import Foundation
import Synchronization
import Testing
@testable import PurrdrAgentFeatures

/// 診斷事件(#688):型別化的連線事件,出口是系統 Console 與可分享的診斷檔(只有類別、代碼與主機匿名序號)。
@Suite("診斷事件")
struct DiagnosticEventsTests {
    final class Console: Sendable {
        private let lines = Mutex<[DiagnosticEvent]>([])
        var sink: @Sendable (DiagnosticEvent) -> Void { { event in self.lines.withLock { $0.append(event) } } }
        var events: [DiagnosticEvent] { lines.withLock { $0 } }
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func make(sink: RecordingDiagnosticSink, console: Console = Console(), enabled: Bool = true) -> DiagnosticEvents {
        DiagnosticEvents(sink: sink, isEnabled: { enabled }, console: console.sink, clock: { now })
    }

    static func records(_ sink: RecordingDiagnosticSink) -> [DiagnosticEventRecord] {
        sink.entries.compactMap { if case .event(let record) = $0 { record } else { nil } }
    }

    @Test("中斷事件寫進診斷檔:類別、代碼、撥號序號與壽命,主機只有匿名序號")
    func droppedEventIsRecordedWithAnonymousHost() async {
        let sink = RecordingDiagnosticSink()
        let events = Self.make(sink: sink)
        events.record(.dropped(host: "secret.example.ts.net", dial: 3, reason: .keepaliveTimeout, lifetimeSeconds: 912, detail: nil))
        await events.flush()

        #expect(Self.records(sink) == [
            DiagnosticEventRecord(at: Self.now, category: "ssh", code: "dropped", reason: "keepalive_timeout", host: 1, dial: 3, value: 912)
        ])
        let line = DiagnosticLogEncoder.line(.event(Self.records(sink)[0]))
        #expect(!line.contains("secret.example.ts.net"))
        #expect(line.contains("\"host\":1"))
        #expect(line.contains("\"kind\":\"event\""))
    }

    @Test("同一台主機序號固定,新主機遞增")
    func ordinalsAreStable() async {
        let sink = RecordingDiagnosticSink()
        let events = Self.make(sink: sink)
        events.record(.connected(host: "a.local", dial: 1))
        events.record(.connected(host: "b.local", dial: 1))
        events.record(.connected(host: "a.local", dial: 2))
        await events.flush()
        #expect(Self.records(sink).map(\.host) == [1, 2, 1])
    }

    @Test("撥號失敗只記錯誤種類,不記含指紋的內容;網路切換、回前景決策不帶主機")
    func otherEvents() async {
        let sink = RecordingDiagnosticSink()
        let events = Self.make(sink: sink)
        events.record(.dialFailed(host: "h", dial: 2, error: "hostKeyUnverified", detail: "SHA256:abcdef"))
        events.record(.networkChanged(droppedConnections: 2, detail: "satisfied:wifi → satisfied:cellular"))
        events.record(.foregroundDecision(backgroundSeconds: 40, redial: true))
        await events.flush()
        let records = Self.records(sink)
        #expect(records.map(\.code) == ["dial_failed", "network_changed", "foreground"])
        #expect(records[0].reason == "hostKeyUnverified")
        #expect(records[1].host == nil && records[1].value == 2)
        #expect(records[2].reason == "redial" && records[2].value == 40)
        for record in records {
            let line = DiagnosticLogEncoder.line(.event(record))
            #expect(!line.contains("abcdef") && !line.contains("wifi"))
        }
    }

    @Test("「操作記錄」關閉:診斷檔不寫連線事件,Console 照記")
    func disabledSkipsFile() async {
        let sink = RecordingDiagnosticSink()
        let console = Console()
        let events = Self.make(sink: sink, console: console, enabled: false)
        events.record(.connected(host: "h", dial: 1))
        await events.flush()
        #expect(sink.entries.isEmpty)
        #expect(console.events == [.connected(host: "h", dial: 1)])
    }

    @Test("Console 文字:固定文字與 SSH 舊格式一致")
    func consoleText() {
        #expect(DiagnosticEvent.connected(host: "h", dial: 3).consoleText == "dial 3 connected")
        let dropped = DiagnosticEvent.dropped(host: "h", dial: 7, reason: .networkError, lifetimeSeconds: 2, detail: "reset")
        #expect(dropped.consoleText == "dial 7 dropped after 2s: network error: reset")
        #expect(dropped.consoleFixedText == "dial 7 dropped after 2s: network error")
    }
}
