import Foundation
import Testing
@testable import PurrdrAgentFeatures
@testable import PurrdrFeatures

/// 記下寫入內容的假標記儲存(注入的寫檔器)。
final class MemoryCrashMarkerStore: CrashMarkerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var writes = 0
    var writeCount: Int { lock.withLock { writes } }
    var current: Data? { lock.withLock { data } }
    func write(_ data: Data) { lock.withLock { self.data = data; writes += 1 } }
    func read() -> Data? { lock.withLock { data } }
    func remove() { lock.withLock { data = nil } }
}

@Suite("診斷記錄:閃退", .serialized)
@MainActor
struct CrashDiagnosticsTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func reporter(_ store: MemoryCrashMarkerStore) -> CrashReporter {
        CrashReporter(store: store, environment: DiagnosticEnvironment(app: "0.52.2 (7)", os: "iOS 27.0.1", device: "iPhone18,1"), clock: { now })
    }

    static func recorder(_ sink: RecordingDiagnosticSink, enabled: Bool = true) -> DiagnosticRecorder {
        let defaults = UserDefaults(suiteName: "crash-\(UUID().uuidString)")!
        defaults.set(enabled, forKey: HitchLogSettings.enabledKey)
        return DiagnosticRecorder(sink: sink, defaults: defaults, system: { .sample }, wallClock: { now })
    }

    @Test("中止前同步寫一個標記:例外名稱、原因、時間、app 版本、iOS 版本、機型")
    func writesMarkerBeforeTermination() throws {
        let store = MemoryCrashMarkerStore()
        Self.reporter(store).exceptionWillTerminate(name: "NSInternalInconsistencyException", reason: "invalid number of items in section 0")
        #expect(store.writeCount == 1)
        let data = try #require(store.current)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["name"] as? String == "NSInternalInconsistencyException")
        #expect(object["reason"] == nil, "標記不留原因原文")
        #expect(object["reasonHash"] as? String == DiagnosticHash.reason("invalid number of items in section 0"))
        #expect((object["reasonHash"] as? String)?.count == 16)
        #expect(object["app"] as? String == "0.52.2 (7)")
        #expect(object["os"] as? String == "iOS 27.0.1")
        #expect(object["device"] as? String == "iPhone18,1")
        #expect(object["t"] as? Double == Self.now.timeIntervalSince1970)
    }

    @Test("原因很長時標記仍很小(只存雜湊)")
    func longReasonKeepsMarkerSmall() throws {
        let store = MemoryCrashMarkerStore()
        Self.reporter(store).exceptionWillTerminate(name: "N", reason: String(repeating: "x", count: 50_000))
        #expect(try #require(store.current).count < 1_000)
    }

    @Test("下次啟動:標記變成一筆閃退記錄,標記刪除;記錄逐欄一致")
    func recoversPendingMarker() throws {
        let store = MemoryCrashMarkerStore()
        Self.reporter(store).exceptionWillTerminate(name: "NSRangeException", reason: "index 3 beyond bounds")
        let sink = RecordingDiagnosticSink()
        let recorder = Self.recorder(sink)
        Self.reporter(store).recoverPending(into: recorder)

        #expect(store.current == nil)
        #expect(sink.entries == [.crash(CrashRecord(
            timestamp: Self.now, name: "NSRangeException", reasonHash: DiagnosticHash.reason("index 3 beyond bounds"),
            environment: DiagnosticEnvironment(app: "0.52.2 (7)", os: "iOS 27.0.1", device: "iPhone18,1")))])
        // 再啟動一次不會重複記。
        Self.reporter(store).recoverPending(into: recorder)
        #expect(sink.entries.count == 1)
    }

    @Test("卡頓開關關閉時仍記閃退")
    func recordsCrashWhenHitchLoggingIsOff() {
        let store = MemoryCrashMarkerStore()
        Self.reporter(store).exceptionWillTerminate(name: "N", reason: "r")
        let sink = RecordingDiagnosticSink()
        let recorder = Self.recorder(sink, enabled: false)
        #expect(!recorder.isEnabled)
        Self.reporter(store).recoverPending(into: recorder)
        #expect(sink.entries.count == 1)
    }

    @Test("標記壞掉:丟掉不記,不當掉")
    func discardsCorruptMarker() {
        let store = MemoryCrashMarkerStore()
        store.write(Data("not json".utf8))
        let sink = RecordingDiagnosticSink()
        Self.reporter(store).recoverPending(into: Self.recorder(sink))
        #expect(sink.entries.isEmpty)
        #expect(store.current == nil)
    }

    @Test("編碼成 JSON Lines 的 crash 一行")
    func encodesCrashLine() throws {
        let line = DiagnosticLogEncoder.line(.crash(CrashRecord(
            timestamp: Self.now, name: "N", reasonHash: DiagnosticHash.reason("r"), environment: DiagnosticEnvironment(app: "a", os: "o", device: "d"))))
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "crash")
        #expect(object["name"] as? String == "N")
        #expect(object["reason"] == nil)
        #expect(object["reasonHash"] as? String == DiagnosticHash.reason("r"))
        #expect(object["app"] as? String == "a")
        #expect(object["os"] as? String == "o")
        #expect(object["device"] as? String == "d")
        #expect(object["v"] as? Int == 1)
    }

    @Test("檔案標記儲存:寫、讀、刪")
    func fileMarkerStore() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileCrashMarkerStore(directory: directory)
        #expect(store.read() == nil)
        store.write(Data("abc".utf8))
        #expect(store.read() == Data("abc".utf8))
        store.remove()
        #expect(store.read() == nil)
    }

    @Test("閃退經記錄檔匯出,清除作用在整份")
    func exportsAndClearsWithHitchLog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DiagnosticLogFile(directory: directory)
        file.append([.crash(CrashRecord(timestamp: Self.now, name: "N", reasonHash: DiagnosticHash.reason("r"), environment: DiagnosticEnvironment(app: "a", os: "o", device: "d"))), DiagnosticLogFileTests.entry(50)])
        let url = try #require(await file.exportFile(meta: nil))
        let lines = try DiagnosticLogFileTests.lines(url)
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"kind\":\"crash\""))
        await file.clear()
        #expect(await file.exportFile(meta: nil) == nil)
    }
}
