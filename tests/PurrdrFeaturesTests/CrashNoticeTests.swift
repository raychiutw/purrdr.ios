import Foundation
import Testing
@testable import PurrdrAgentFeatures
@testable import PurrdrFeatures

/// 啟動提示「上次 Purrdr 意外關閉」(#632):每筆閃退只提示一次、只在一個視窗顯示、解鎖後才出現。
@Suite("診斷記錄:啟動提示", .serialized)
@MainActor
struct CrashNoticeTests {
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func record(at time: Date = t0, name: String = "NSRangeException") -> CrashRecord {
        CrashRecord(timestamp: time, name: name, reason: "r", app: "a", os: "o", device: "d")
    }

    static func make(store: InMemoryCrashNoticeStore = InMemoryCrashNoticeStore()) -> (CrashNoticeModel, HitchRecorder, InMemoryCrashNoticeStore) {
        let defaults = UserDefaults(suiteName: "crashnotice-\(UUID().uuidString)")!
        let recorder = HitchRecorder(sink: RecordingHitchSink(), defaults: defaults, system: { .sample }, wallClock: { t0 })
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

    @Test("同一次閃退的第二筆記錄(標記加 MetricKit 報告)不再提示第二次")
    func sameCrashSecondRecordDoesNotPromptAgain() {
        let (model, recorder, _) = Self.make()
        recorder.recordCrash(Self.record())
        recorder.recordCrash(Self.record(at: Self.t0.addingTimeInterval(30), name: "metrickit"))
        #expect(model.pending == Self.record())
        model.dismiss()
        recorder.recordCrash(Self.record(at: Self.t0.addingTimeInterval(60), name: "metrickit"))
        #expect(model.pending == nil)
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
