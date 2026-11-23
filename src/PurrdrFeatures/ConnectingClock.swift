import Foundation
import PurrdrAgentFeatures
import PurrdrCore

/// Agent 列表「仍在連線」用的計時器(#221、#492)。
///
/// 只在前景(`isActive`)跑;進背景不推進(週期性更新一律以 `scenePhase == .active` 為條件，否則背景中主執行緒仍在更新
/// SwiftUI,會被看門狗 0x8BADF00D 殺掉)。連線狀態行到 `slowConnectionThreshold` 換成「仍在連線」後不再需要計時，直接停止。
public enum ConnectingClock {
    /// 還有主機在「連線中」(還沒過門檻)才需要每秒推進現在時間。
    public static func needsTicks(for statuses: [HostLoadStatus]) -> Bool {
        statuses.contains { $0.state == .connecting }
    }

    /// 進入時先更新一次(從背景回來時現在時間是舊的)，之後每秒更新，直到不需要、不在前景或被取消。
    @MainActor
    public static func run(
        isActive: Bool,
        needsTicks: @MainActor () -> Bool,
        tick: @MainActor (Date) -> Void,
        clock: @MainActor () -> Date = { Date() },
        sleep: Sleep
    ) async {
        guard isActive else { return }
        while needsTicks(), !Task.isCancelled {
            tick(clock())
            do { try await sleep(.seconds(1)) } catch { return }
        }
    }
}
