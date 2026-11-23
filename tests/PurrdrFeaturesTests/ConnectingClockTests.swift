import Foundation
import PurrdrAgentFeatures
import PurrdrCore
import Testing
@testable import PurrdrFeatures

/// 列表「仍在連線」計時器(#492):0.49.0 的 `.task(id: hasConnectingHosts)` 每秒寫 `now`、沒有前景條件，
/// 進背景後主執行緒仍在更新 SwiftUI,被看門狗 0x8BADF00D 殺掉。
@MainActor
@Suite("連線計時器")
struct ConnectingClockTests {
    final class Recorder: @unchecked Sendable {
        var sleeps = 0
        var ticks: [Date] = []
    }

    /// 等待超過 `limit` 次就取消，讓「會一直跑」的實作在測試裡也會結束(並因次數不符而失敗)。
    private func run(isActive: Bool, needs: @escaping @MainActor () -> Bool, recorder: Recorder, limit: Int = 50) async {
        await ConnectingClock.run(
            isActive: isActive, needsTicks: needs, tick: { recorder.ticks.append($0) },
            sleep: { _ in
                recorder.sleeps += 1
                if recorder.sleeps >= limit { throw CancellationError() }
            })
    }

    @Test("不在前景:計時器不推進")
    func doesNotTickInBackground() async {
        let recorder = Recorder()
        await run(isActive: false, needs: { true }, recorder: recorder)
        #expect(recorder.ticks.isEmpty)
        #expect(recorder.sleeps == 0)
    }

    @Test("前景:先更新一次再每秒推進，到不需要時停止")
    func stopsOnceNoLongerNeeded() async {
        let recorder = Recorder()
        await run(isActive: true, needs: { recorder.ticks.count < 3 }, recorder: recorder)
        #expect(recorder.ticks.count == 3)
        #expect(recorder.sleeps == 3)
    }

    @Test("需要計時的條件:只有「連線中」才要，出現「仍在連線」後不再需要")
    func needsTicksOnlyWhileConnecting() {
        func status(_ state: HostLoadStatus.State) -> HostLoadStatus {
            HostLoadStatus(host: .demo, name: "Mac", icon: .macMini, state: state)
        }
        #expect(ConnectingClock.needsTicks(for: []) == false)
        #expect(ConnectingClock.needsTicks(for: [status(.connecting)]))
        #expect(ConnectingClock.needsTicks(for: [status(.connecting), status(.stillConnecting)]))
        #expect(ConnectingClock.needsTicks(for: [status(.stillConnecting)]) == false)
    }
}
