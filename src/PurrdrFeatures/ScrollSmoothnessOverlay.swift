#if DEBUG
import Observation
import PurrdrCore
import SwiftUI

/// 除錯層的量測接收端(#484):聊天列表呼叫 `report`，`ScrollSmoothnessOverlay` 讀 `log`。只在除錯建置編譯。
@MainActor
@Observable
final class ScrollSmoothnessProbe: ScrollSmoothnessReporting {
    private(set) var log = ScrollSmoothnessLog()

    func report(_ snapshot: ScrollSmoothnessSnapshot) {
        guard snapshot != log.latest else { return }
        log.record(snapshot)
    }
}

/// 疊在聊天畫面上的順暢度顯示:離底距離、可見列數與疑似黑框次數，供截圖留證(#484)。
struct ScrollSmoothnessOverlay: View {
    let probe: ScrollSmoothnessProbe

    var body: some View {
        let log = probe.log
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: log.latest?.overlayText ?? "尚無量測")
            Text(verbatim: "樣本 \(log.sampleCount) ・ 疑似黑框 \(log.suspectedBlankCount) 次")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(6)
        .background((log.latest?.isSuspectedBlank == true ? Color.red : Color.black).opacity(0.7), in: .rect(cornerRadius: 6))
        .padding(.top, 4)
        .padding(.leading, 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
