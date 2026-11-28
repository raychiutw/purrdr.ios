import Foundation
import Testing

@testable import PurrdrTestSupport

@Suite("UI 測試啟動看門狗")
struct LaunchWatchdogTests {
    private static let policy = LaunchWatchdogPolicy(readinessTimeout: 30, maxAttempts: 2)
    private static let stuck = LaunchDiagnosis(appState: "runningForeground", appIsGone: false, crashReportFound: false)
    private static let crashed = LaunchDiagnosis(appState: "notRunning", appIsGone: true, crashReportFound: true)

    private final class Recorder {
        var launches = 0
        var terminates = 0
        var logs: [String] = []
        var timeouts: [TimeInterval] = []
    }

    private func run(policy: LaunchWatchdogPolicy = policy, readyOnAttempt: Int?, diagnosis: LaunchDiagnosis = stuck) -> (String?, Recorder) {
        let recorder = Recorder()
        let result = LaunchWatchdog.run(
            policy: policy,
            launch: { recorder.launches += 1 },
            awaitReady: { attempt, timeout in recorder.timeouts.append(timeout); return attempt == readyOnAttempt },
            diagnose: { diagnosis },
            terminate: { recorder.terminates += 1 },
            log: { recorder.logs.append($0) })
        return (result, recorder)
    }

    @Test("第一次就緒:啟動一次、不重來、不留記錄")
    func readyImmediately() {
        let (result, recorder) = run(readyOnAttempt: 1)
        #expect(result == nil)
        #expect(recorder.launches == 1 && recorder.terminates == 0 && recorder.logs.isEmpty)
        #expect(recorder.timeouts == [30])
    }

    @Test("第一次卡住:結束 app 後重來,第二次就緒就通過,並留下一行記錄")
    func retriesOnceAndPasses() {
        let (result, recorder) = run(readyOnAttempt: 2)
        #expect(result == nil)
        #expect(recorder.launches == 2 && recorder.terminates == 1)
        #expect(recorder.logs.count == 1)
        #expect(recorder.logs[0].contains("第 1/2 次") && recorder.logs[0].contains("重來"))
    }

    @Test("重來後還是卡住:失敗,訊息寫明是啟動卡住與兩次的原因")
    func failsAfterRetryLimit() throws {
        let (result, recorder) = run(readyOnAttempt: nil)
        let message = try #require(result)
        #expect(recorder.launches == 2 && recorder.terminates == 2)
        #expect(message.contains("啟動卡住") && message.contains("30 秒") && message.contains("第 1 次") && message.contains("第 2 次"))
        #expect(recorder.logs.count == 2)
    }

    @Test("有崩潰報告:不重來(不掩蓋真實崩潰),訊息說是崩潰")
    func crashIsNotRetried() throws {
        let (result, recorder) = run(readyOnAttempt: nil, diagnosis: Self.crashed)
        let message = try #require(result)
        #expect(recorder.launches == 1)
        #expect(message.contains("崩潰") && !message.contains("啟動卡住"))
    }

    @Test("重來次數 1 = 不重來")
    func singleAttemptNeverRetries() {
        let (result, recorder) = run(policy: .init(readinessTimeout: 30, maxAttempts: 1), readyOnAttempt: 2)
        #expect(result != nil)
        #expect(recorder.launches == 1)
    }

    @Test("看不到崩潰報告(nil)時照一般規則重來")
    func unknownCrashReportStillRetries() {
        let unknown = LaunchDiagnosis(appState: "notRunning", appIsGone: true, crashReportFound: nil)
        let (result, recorder) = run(readyOnAttempt: 2, diagnosis: unknown)
        #expect(result == nil)
        #expect(recorder.logs[0].contains("無法檢查崩潰報告") && recorder.logs[0].contains("已不在執行"))
    }
}
