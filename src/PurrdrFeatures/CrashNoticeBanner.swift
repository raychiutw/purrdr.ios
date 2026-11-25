import PurrdrAgentFeatures
import SwiftUI

/// 啟動提示「上次 Purrdr 意外關閉」(#632):頂端浮出的玻璃橫幅,附「分享記錄」與「關閉」。
/// 不計時消失、不擋住畫面其他部分;只在一個視窗顯示、App 鎖解開後才出現(接線在 `TopNavigationView`)。
struct CrashNoticeBanner: View {
    let model: CrashNoticeModel
    @State private var isSharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Purrdr closed unexpectedly last time")
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondaryText)
            }
            HStack(spacing: 8) {
                Button("Share Log") {
                    guard !isSharing else { return }
                    isSharing = true
                    Task {
                        defer { isSharing = false }
                        guard let url = await model.exportFile() else { return }
                        #if os(iOS)
                        SystemSharePresenter.present(url)
                        #endif
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("crashNotice.share")
                Button("Dismiss") { model.dismiss() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("crashNotice.dismiss")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingGlass(in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { model.dismiss() }
        .accessibilityIdentifier("crashNotice.banner")
        // 出現時念出來。
        .onAppear {
            model.didShow()
            AccessibilityNotification.Announcement(String(localized: "Purrdr closed unexpectedly last time")).post()
        }
        // 提示開著時又換成另一筆閃退,也在顯示時記下。
        .onChange(of: model.pending) { _, _ in model.didShow() }
    }
}

/// 把橫幅掛在視窗頂端:只在 `CrashNoticeModel` 指定的那個視窗顯示;App 鎖定中不顯示,解鎖後出現。
/// 直接觀察 `AppLock.isLocked`,不經 `whenUnlocked`(那只留一個等待導航,會和推播點擊導航互相覆蓋)。
struct CrashNoticeModifier: ViewModifier {
    let model: CrashNoticeModel?
    let appLock: AppLock?
    @State private var window = UUID()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let model, model.isShown(in: window, appLocked: appLock?.isLocked ?? false) {
                    CrashNoticeBanner(model: model)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onAppear { model?.attach(window: window) }
            .onDisappear { model?.detach(window: window) }
    }
}

extension View {
    func crashNotice(_ model: CrashNoticeModel?, appLock: AppLock?) -> some View {
        modifier(CrashNoticeModifier(model: model, appLock: appLock))
    }
}
