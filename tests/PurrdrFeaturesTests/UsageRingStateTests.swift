import Foundation
import PurrdrCore
@testable import PurrdrFeatures
import Testing

/// 用量環的載入狀態(#644):loading → 有資料／空環;載入用系統 ProgressView,不自畫。
@Suite("用量環載入狀態")
struct UsageRingStateTests {
    static let summary = UsageSummary(source: .context, percent: 40, display: .used, level: .normal)

    @Test("資料還沒回來:載入中;任一來源先到就先顯示百分比")
    func loadingThenValue() {
        #expect(UsageRingState.make(summary: nil, isContextLoading: true, isPlanLoading: true) == .loading)
        #expect(UsageRingState.make(summary: nil, isContextLoading: true, isPlanLoading: false) == .loading)
        #expect(UsageRingState.make(summary: nil, isContextLoading: false, isPlanLoading: true) == .loading)
        #expect(UsageRingState.make(summary: Self.summary, isContextLoading: true, isPlanLoading: true) == .value(Self.summary))
    }

    @Test("都讀完還是沒有資料(沒有用量、未安裝、錯誤):空環")
    func emptyWhenSettled() {
        #expect(UsageRingState.make(summary: nil, isContextLoading: false, isPlanLoading: false) == .empty)
    }

    @Test("載入用系統 ProgressView,不自畫動畫")
    func usesSystemProgressView() throws {
        let text = try GlassLevelUsageTests.source("ConversationUsageViews.swift")
        #expect(text.contains("ProgressView()"))
        for banned in [".repeatForever", "TimelineView", "Canvas", "withAnimation(.linear"] {
            #expect(!text.contains(banned), "用量環載入不要自畫動畫:\(banned)")
        }
    }
}
