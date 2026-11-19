import SwiftUI

/// 錯誤訊息：文字用主要色(或外層指定的字色),系統紅只上在圖示(#240,HIG 盤點 3.4)。
struct ErrorLabel: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
