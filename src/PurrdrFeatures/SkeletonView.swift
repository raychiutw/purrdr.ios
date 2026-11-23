import PurrdrAgentFeatures
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 骨架畫面(#496)的共用外觀:套在**真實的列元件**(用假資料撐出同樣版型)上,`redacted(.placeholder)` 畫成灰塊,
/// 加上統一的脈動(1.6 秒 opacity 0.55↔1;開「減少動態效果」時不動),並讓 VoiceOver 只念一個「載入中」。
///
/// 只在「第一次載入、沒有任何內容」時使用(`SkeletonLoading.isShown`);按鈕送出中、下載進度等動作進行中維持轉圈。
extension View {
    /// - Parameters:
    ///   - identifier: 這一區的 accessibility identifier(UI 測試用)。
    ///   - label: VoiceOver 念的文字;預設「載入中」。
    func skeleton(identifier: String, label: LocalizedStringKey = "Loading…") -> some View {
        modifier(SkeletonStyle(identifier: identifier, label: label))
    }
}

private struct SkeletonStyle: ViewModifier {
    let identifier: String
    let label: LocalizedStringKey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    /// UI 測試關掉動畫時(`UIView.setAnimationsEnabled(false)`)也不脈動,免得重複動畫讓 XCUITest 等不到閒置。
    private var pulses: Bool {
        guard SkeletonLoading.pulses(reduceMotion: reduceMotion) else { return false }
        #if canImport(UIKit)
        return UIView.areAnimationsEnabled
        #else
        return true
        #endif
    }

    func body(content: Content) -> some View {
        content
            .redacted(reason: .placeholder)
            .opacity(pulses && dimmed ? SkeletonLoading.pulseLowOpacity : 1)
            .onAppear {
                guard pulses else { return }
                withAnimation(.easeInOut(duration: SkeletonLoading.pulseDuration / 2).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier(identifier)
    }
}

/// 一個佔位塊(設計稿的 `.sk`):沒有真實列元件可套時(例如進度條、頭像)用它拼出版型。
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 7

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.quaternary)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// 帳號頁第一次載入(#496,設計稿 `Skeleton` 帳號頁):會員列、Plus 卡、Plus 功能的佔位,整段一個「載入中」;
/// 設定區(`settings`)照常顯示,不被後台狀態擋住(purrdr://settings 與 Cmd-, 開到的要能用)。
struct AccountSkeletonView: View {
    var settings: AccountSettings?

    var body: some View {
        List {
            Section {
                // 整段只套一次骨架:同一個 Section 只有一個「載入中」元素。
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        SkeletonBlock(width: 44, height: 44, cornerRadius: 22)
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(height: 16).containerRelativeFrame(.horizontal) { width, _ in width * 0.4 }
                            SkeletonBlock(height: 12).containerRelativeFrame(.horizontal) { width, _ in width * 0.62 }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        SkeletonBlock(height: 17).containerRelativeFrame(.horizontal) { width, _ in width * 0.36 }
                        SkeletonBlock(height: 13).containerRelativeFrame(.horizontal) { width, _ in width * 0.7 }
                        SkeletonBlock(height: 44, cornerRadius: 22)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        SkeletonBlock(height: 15).containerRelativeFrame(.horizontal) { width, _ in width * 0.5 }
                        SkeletonBlock(height: 15).containerRelativeFrame(.horizontal) { width, _ in width * 0.44 }
                    }
                }
                .skeleton(identifier: "account.loading")
            }
            if let settings { SettingsSections(settings) }
        }
        .appGroupedList()
    }
}

/// 訂閱方案(StoreKit 價格)載入中的佔位(#496):兩列方案。
struct PlanOptionsSkeleton: View {
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SkeletonBlock(height: 17).containerRelativeFrame(.horizontal) { width, _ in width * 0.5 }
            SkeletonBlock(height: 17).containerRelativeFrame(.horizontal) { width, _ in width * 0.42 }
        }
        .padding(.vertical, 4)
        .skeleton(identifier: identifier)
    }
}
