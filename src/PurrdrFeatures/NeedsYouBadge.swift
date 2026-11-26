import Observation
import PurrdrAgentFeatures

/// 聊天 tab 的徽章數字(#581):根畫面只讀這個數字,不直接讀合併列表,所以列表上別的變化(預覽、狀態)不會讓根畫面重算;
/// 「需要你」的數量真的變了才通知。
@MainActor
@Observable
package final class NeedsYouBadge {
    package private(set) var count: Int
    @ObservationIgnored private let merged: MergedAgentListModel
    @ObservationIgnored private var isTracking = false

    package init(merged: MergedAgentListModel) {
        self.merged = merged
        count = merged.needsYouCount()
    }

    /// 開始跟著列表更新數字(只啟動一次)。
    package func start() {
        guard !isTracking else { return }
        isTracking = true
        track()
    }

    private func track() {
        let latest = withObservationTracking {
            merged.needsYouCount()
        } onChange: { [weak self] in
            // onChange 在變更前呼叫:讓出一次再讀新值並重新追蹤。
            Task { @MainActor in self?.track() }
        }
        if latest != count { count = latest }
    }
}
