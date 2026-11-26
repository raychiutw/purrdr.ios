import PurrdrAgentFeatures
import SwiftUI

/// 錯誤訊息：文字用主要色(或外層指定的字色),系統紅只上在圖示(#240,HIG 盤點 3.4)。
///
/// 也是「操作記錄」(#637)的唯一接縫:出現時(內容換了也算)送一筆錯誤記錄給診斷記錄器,
/// 只含類別、錯誤碼與功能區,不含訊息原文;畫面重繪不重複記。
struct ErrorLabel: View {
    let message: String
    let area: String
    let descriptor: ErrorDescriptor

    /// `area`:顯示這個錯誤的畫面識別(例如 `NewChat`)。`error`:錯誤的類別與錯誤碼,一定要帶(畫面 model 保留 `DisplayedError`)。
    init(_ message: String, area: String, error: ErrorDescriptor) {
        self.message = message
        self.area = area
        descriptor = error
    }

    /// 直接帶錯誤值。
    init(_ message: String, area: String, error: any Error) {
        self.init(message, area: area, error: ErrorDescriptor(error))
    }

    /// 錯誤圖示;停止列的送不出也用它(#220)。
    nonisolated static let symbolName = "exclamationmark.triangle.fill"

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: Self.symbolName)
                .foregroundStyle(.red)
        }
        .reportsErrorDisplay(fingerprint: message.hashValue, descriptor: descriptor, area: area)
    }
}

extension View {
    /// 這個畫面元件顯示錯誤時記進操作記錄(見 `ErrorLabel`);alert 也用它。
    /// `isShowing` 為 false(沒有錯誤)時不記、並視為已消失。
    ///
    /// 有錯誤時記一筆(alert 用);`error` 為 `nil` 時不記。
    func reportsErrorDisplay(_ error: DisplayedError?, area: String) -> some View {
        modifier(ErrorDisplayReporting(fingerprint: error?.hashValue ?? 0, descriptor: error?.descriptor, area: area, isShowing: error != nil))
    }

    func reportsErrorDisplay(fingerprint: Int, descriptor: ErrorDescriptor, area: String, isShowing: Bool = true) -> some View {
        modifier(ErrorDisplayReporting(fingerprint: fingerprint, descriptor: descriptor, area: area, isShowing: isShowing))
    }
}

private struct ErrorDisplayReporting: ViewModifier {
    let fingerprint: Int
    let descriptor: ErrorDescriptor?
    let area: String
    let isShowing: Bool

    @Environment(\.hitchRecorder) private var recorder
    @State private var instance = UUID()

    func body(content: Content) -> some View {
        content
            .task(id: isShowing ? fingerprint : nil) {
                guard isShowing, let descriptor else {
                    recorder?.errorHidden(instance: instance)
                    return
                }
                recorder?.errorShown(instance: instance, fingerprint: fingerprint, descriptor: descriptor, area: area)
            }
            .onDisappear { recorder?.errorHidden(instance: instance) }
    }
}
