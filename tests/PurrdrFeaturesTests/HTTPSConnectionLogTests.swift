import Foundation
import PurrdrHTTPS
import Testing
@testable import PurrdrAgentFeatures
@testable import PurrdrFeatures

/// HTTPS 連線事件(#689)進診斷事件:category `https`,診斷檔只有代碼與主機匿名序號,不含位址與錯誤描述。
@Suite("HTTPS 連線紀錄")
struct HTTPSConnectionLogTests {
    @Test("中斷事件進診斷檔:category https、原因代碼、壽命秒數,位址與錯誤描述不進檔案")
    func droppedGoesToTheFileWithoutAddressOrDetail() async {
        let sink = RecordingDiagnosticSink()
        let events = DiagnosticEventsTests.make(sink: sink)
        let log = HTTPSConnectionLog.events(events, host: "secret.tail1234.ts.net")

        log(.connected(dial: 1))
        log(.dropped(dial: 1, reason: .networkError("socket secret.tail1234.ts.net reset"), lifetime: .seconds(42)))
        log(.dropped(dial: 2, reason: .heartbeatTimeout, lifetime: .seconds(7)))
        log(.dialFailed(dial: 3, error: "deviceTokenRevoked", elapsed: .seconds(1)))
        await events.flush()

        let records = DiagnosticEventsTests.records(sink)
        #expect(records.map(\.category) == ["https", "https", "https", "https"])
        #expect(records.map(\.code) == ["connected", "dropped", "dropped", "dial_failed"])
        #expect(records.map(\.reason) == [nil, "network_error", "heartbeat_timeout", "deviceTokenRevoked"])
        #expect(records[1].value == 42)
        #expect(records.allSatisfy { $0.host == 1 })
        for entry in sink.entries {
            let line = DiagnosticLogEncoder.line(entry)
            #expect(!line.contains("secret"))
        }
    }

    @Test("Console 文字:固定文字帶原因,SSH 事件的 category 仍是 ssh")
    func consoleCategoryFollowsTheTransport() {
        let https = HTTPSConnectionLog.diagnosticEvent(.dropped(dial: 2, reason: .tokenRejected, lifetime: .seconds(5)), host: "h")
        #expect(https.consoleCategory == "https")
        #expect(https.consoleFixedText == "dial 2 dropped after 5s: device token rejected")
        #expect(DiagnosticEvent.connected(host: "h", dial: 1).consoleCategory == "ssh")
    }
}
