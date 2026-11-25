import Foundation
import Testing
@testable import PurrdrAgentFeatures
@testable import PurrdrFeatures

/// 啟動提示「上次 Purrdr 意外關閉」(#632):每筆閃退只提示一次、只在一個視窗顯示、解鎖後才出現。
@Suite("診斷記錄:啟動提示", .serialized)
@MainActor
struct CrashNoticeTests {
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func record(at time: Date = t0, name: String = "NSRangeException", app: String = "a") -> CrashRecord {
        CrashRecord(timestamp: time, name: name, reason: "r", app: app, os: "o", device: "d")
    }

    /// MetricKit 報告:時間是整份 payload 區間的尾端,區間預設 24 小時。
    static func report(
        end: Date, hours: Double = 24, name: String? = "NSRangeException", app: String = "a"
    ) -> MetricKitCrashReport {
        MetricKitCrashReport(
            timestamp: end, exceptionType: nil, signal: 6, terminationReason: nil, exceptionName: name,
            exceptionReason: nil, frames: [], app: app, os: "o", device: "d", periodStart: end.addingTimeInterval(-hours * 3_600))
    }

    static func make(store: InMemoryCrashNoticeStore = InMemoryCrashNoticeStore()) -> (CrashNoticeModel, DiagnosticRecorder, InMemoryCrashNoticeStore) {
        let defaults = UserDefaults(suiteName: "crashnotice-\(UUID().uuidString)")!
        let recorder = DiagnosticRecorder(sink: RecordingDiagnosticSink(), defaults: defaults, system: { .sample }, wallClock: { t0 })
        return (CrashNoticeModel(recorder: recorder, store: store), recorder, store)
    }

    @Test("啟動前已記下的閃退:模型接上後就有待提示的記錄")
    func picksUpCrashRecordedBeforeAttach() {
        let (_, recorder, store) = Self.make()
        recorder.recordCrash(Self.record())
        let model = CrashNoticeModel(recorder: recorder, store: store)
        #expect(model.pending == Self.record())
    }

    @Test("啟動後才送到的閃退(MetricKit)也會提示")
    func picksUpLaterCrash() {
        let (model, recorder, _) = Self.make()
        #expect(model.pending == nil)
        recorder.recordCrash(Self.record())
        #expect(model.pending == Self.record())
    }

    @Test("按關閉:不再提示,下次啟動也不會(已提示存本機)")
    func dismissIsRemembered() {
        let (model, recorder, store) = Self.make()
        recorder.recordCrash(Self.record())
        model.dismiss()
        #expect(model.pending == nil)
        let next = CrashNoticeModel(recorder: recorder, store: store)
        #expect(next.pending == nil)
    }

    @Test("同一次閃退:MetricKit 報告的 24 小時區間涵蓋中止前標記、同版本同例外名稱,就不再提示第二次(仍寫入記錄)")
    func reportWhosePeriodCoversMarkerIsSameCrash() {
        let sink = RecordingDiagnosticSink()
        let defaults = UserDefaults(suiteName: "crashnotice-\(UUID().uuidString)")!
        let recorder = DiagnosticRecorder(sink: sink, defaults: defaults, system: { .sample }, wallClock: { Self.t0 })
        let model = CrashNoticeModel(recorder: recorder, store: InMemoryCrashNoticeStore())
        recorder.recordCrash(Self.record())
        // 報告的時間是區間尾端(標記之後 3 小時),和標記差遠超過 10 分鐘。
        recorder.recordCrashReport(Self.report(end: Self.t0.addingTimeInterval(3 * 3_600)))
        #expect(model.pending == Self.record())
        model.dismiss()
        recorder.recordCrashReport(Self.report(end: Self.t0.addingTimeInterval(3 * 3_600)))
        #expect(model.pending == nil)
        #expect(sink.entries.count == 3, "三筆都要寫進記錄")
    }

    @Test("標記已提示過(上一次啟動),這次啟動才收到的 MetricKit 報告也算同一次")
    func reportInLaterLaunchMatchesNoticedMarker() {
        let store = InMemoryCrashNoticeStore()
        let (first, recorder, _) = Self.make(store: store)
        recorder.recordCrash(Self.record())
        first.didShow()
        let (second, secondRecorder, _) = Self.make(store: store)
        secondRecorder.recordCrashReport(Self.report(end: Self.t0.addingTimeInterval(20 * 3_600)))
        #expect(second.pending == nil)
    }

    @Test("MetricKit 報告:版本不同、例外名稱不同、區間沒涵蓋標記,都是另一次閃退")
    func reportThatDoesNotMatchPromptsAgain() {
        for report in [
            Self.report(end: Self.t0.addingTimeInterval(3_600), app: "b"),
            Self.report(end: Self.t0.addingTimeInterval(3_600), name: "NSInvalidArgumentException"),
            Self.report(end: Self.t0.addingTimeInterval(48 * 3_600)),
            Self.report(end: Self.t0.addingTimeInterval(-3_600)),
        ] {
            let (model, recorder, _) = Self.make()
            recorder.recordCrash(Self.record())
            model.dismiss()
            recorder.recordCrashReport(report)
            #expect(model.pending != nil, "\(report.app) \(report.exceptionName ?? "-") \(report.timestamp)")
        }
    }

    @Test("MetricKit 報告沒有例外名稱(Swift 執行期錯誤):只比區間與版本")
    func reportWithoutExceptionNameMatchesOnPeriodAndApp() {
        let (model, recorder, _) = Self.make()
        recorder.recordCrash(Self.record())
        model.dismiss()
        recorder.recordCrashReport(Self.report(end: Self.t0.addingTimeInterval(3_600), name: nil))
        #expect(model.pending == nil)
    }

    @Test("真實形狀的 payload(24 小時區間)經 MetricKitCrashIntake 進來,和同一次的標記不重複提示")
    func intakeFixtureDoesNotDuplicateMarker() {
        let defaults = UserDefaults(suiteName: "crashnotice-\(UUID().uuidString)")!
        let recorder = DiagnosticRecorder(sink: RecordingDiagnosticSink(), defaults: defaults, system: { .sample }, wallClock: { Self.t0 })
        let model = CrashNoticeModel(recorder: recorder, store: InMemoryCrashNoticeStore())
        let end = Date(timeIntervalSince1970: 1_795_593_600)
        recorder.recordCrash(Self.record(at: end.addingTimeInterval(-3 * 3_600), name: "NSInternalInconsistencyException", app: "0.52.2 (7)"))
        model.dismiss()
        MetricKitCrashIntake(recorder: recorder, defaults: defaults).ingest(payloadJSON: MetricKitCrashFixtures.full)
        #expect(model.pending == nil)
    }

    @Test("提示顯示時就記下已提示(不必按關閉):下次啟動不再提示")
    func noticedWhenShownNotOnlyWhenDismissed() {
        let store = InMemoryCrashNoticeStore()
        let (model, recorder, _) = Self.make(store: store)
        recorder.recordCrash(Self.record())
        model.didShow()
        let (next, nextRecorder, _) = Self.make(store: store)
        nextRecorder.recordCrash(Self.record())
        #expect(next.pending == nil)
    }

    @Test("另一次閃退(間隔夠久)再提示一次")
    func laterCrashPromptsAgain() {
        let (model, recorder, _) = Self.make()
        recorder.recordCrash(Self.record())
        model.dismiss()
        let later = Self.record(at: Self.t0.addingTimeInterval(3_600))
        recorder.recordCrash(later)
        #expect(model.pending == later)
    }

    @Test("App 鎖定中不顯示;解鎖後顯示")
    func hiddenWhileAppLocked() {
        let (model, recorder, _) = Self.make()
        let window = UUID()
        model.attach(window: window)
        recorder.recordCrash(Self.record())
        #expect(!model.isShown(in: window, appLocked: true))
        #expect(model.isShown(in: window, appLocked: false))
    }

    @Test("鎖定中有推播導航在等、也有待提示的閃退:解鎖後推播導航照常執行、提示也出現(提示不佔用 whenUnlocked)")
    func pushNavigationSurvivesPendingCrashNotice() async {
        let defaults = UserDefaults(suiteName: "crashnotice-lock-\(UUID().uuidString)")!
        defaults.set(true, forKey: AppLock.enabledKey)
        let lock = AppLock(authenticator: AppLockTests.ScriptedAuthenticator([.success]), defaults: defaults)
        let (model, recorder, _) = Self.make()
        let window = UUID()
        model.attach(window: window)
        var opened: [String] = []

        lock.whenUnlocked { opened.append("w1:p1") }
        recorder.recordCrash(Self.record())
        #expect(lock.isLocked)
        #expect(!model.isShown(in: window, appLocked: lock.isLocked))

        await lock.unlock()
        #expect(opened == ["w1:p1"])
        #expect(model.isShown(in: window, appLocked: lock.isLocked))
    }

    @Test("多視窗只在第一個視窗顯示;它關掉後換下一個")
    func onlyOneWindowShows() {
        let (model, recorder, _) = Self.make()
        let first = UUID(), second = UUID()
        model.attach(window: first)
        model.attach(window: second)
        recorder.recordCrash(Self.record())
        #expect(model.isShown(in: first, appLocked: false))
        #expect(!model.isShown(in: second, appLocked: false))
        model.detach(window: first)
        #expect(model.isShown(in: second, appLocked: false))
    }

    @Test("Swift 執行期錯誤沒有標記,只有 MetricKit 報告:也會提示")
    func metricKitReportAloneStillPrompts() {
        let (model, recorder, _) = Self.make()
        recorder.recordCrashReport(MetricKitCrashReport(
            timestamp: Self.t0, exceptionType: nil, signal: 5, terminationReason: nil, exceptionName: nil,
            exceptionReason: nil, frames: [], app: "a", os: "o", device: "d"))
        #expect(model.pending != nil)
        #expect(model.pending?.timestamp == Self.t0)
    }
}
