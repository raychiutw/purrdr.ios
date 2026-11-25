import PurrdrAgentFeatures
import SwiftUI

/// 骨架畫面(#496)的共用外觀:套在版型與真實內容相同的元件上——有真實的列元件就用它(假資料撐出同樣版型,例如聊天列、用量列),
/// 沒有的(進度條、頭像、泡泡)用 `SkeletonBlock` 拼——`redacted(.placeholder)` 畫成灰塊,
/// 加上統一的脈動(1.6 秒 opacity 0.55↔1;開「減少動態效果」、動畫被關掉或 app 不在前景時不動),並讓 VoiceOver 只念一個「載入中」。
///
/// 只在「第一次載入、沒有任何內容」時使用(`SkeletonLoading.isShown`);按鈕送出中、下載進度等動作進行中維持轉圈。
extension View {
    /// - Parameters:
    ///   - identifier: 這一區的 accessibility identifier(UI 測試用)。
    ///   - label: VoiceOver 念的文字;預設「載入中」。
    ///   - announces: `false` 時對輔助技術隱藏:同一區有好幾個骨架時只讓一個念「載入中」。
    func skeleton(identifier: String, label: LocalizedStringKey = "Loading…", announces: Bool = true) -> some View {
        modifier(SkeletonStyle(identifier: identifier, label: label, announces: announces))
    }
}

extension EnvironmentValues {
    /// 動畫是否啟用(app 在 UI 測試關掉動畫時由 composition root 設成 false;骨架據此不脈動)。
    @Entry public var skeletonAnimationsEnabled = true
}

private struct SkeletonStyle: ViewModifier {
    let identifier: String
    let label: LocalizedStringKey
    let announces: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.skeletonAnimationsEnabled) private var animationsEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var dimmed = false

    private var pulses: Bool {
        SkeletonLoading.pulses(reduceMotion: reduceMotion, animationsEnabled: animationsEnabled, isActive: scenePhase == .active)
    }

    func body(content: Content) -> some View {
        content
            .redacted(reason: .placeholder)
            .opacity(pulses && dimmed ? SkeletonLoading.pulseLowOpacity : 1)
            // 進背景(或關掉動畫)就停,回前景再開始(背景不持續更新畫面,#492)。
            .onChange(of: pulses, initial: true) { _, shouldPulse in
                if shouldPulse {
                    withAnimation(.easeInOut(duration: SkeletonLoading.pulseDuration / 2).repeatForever(autoreverses: true)) {
                        dimmed = true
                    }
                } else {
                    withAnimation(.linear(duration: 0)) { dimmed = false }
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(!announces)
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

/// 清單第一次載入的列骨架(#626):每列一行標題加一行說明,整區一個「載入中」。
/// 裝置清單(通知裝置、登入中的裝置、已配對裝置)與 Git 變更的檔案列共用;局部動作(撤銷中、送出中)仍用小轉圈。
struct RowsSkeleton: View {
    var count = 3
    let identifier: String
    var label: LocalizedStringKey = "Loading…"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBlock(height: 16).containerRelativeFrame(.horizontal) { width, _ in width * 0.5 }
                    SkeletonBlock(height: 12).containerRelativeFrame(.horizontal) { width, _ in width * 0.7 }
                }
            }
        }
        .padding(.vertical, 4)
        .skeleton(identifier: identifier, label: label)
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
