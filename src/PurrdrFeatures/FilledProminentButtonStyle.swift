import PurrdrCore
import SwiftUI

extension View {
    /// 填色底白字的主要按鈕(`.borderedProminent`),底色是紅底角色(有主機主題時用主題的填色;#70)。
    func filledProminentButtonStyle() -> some View {
        modifier(FilledProminentModifier(isGlass: false))
    }

    /// 同 `filledProminentButtonStyle()`,Liquid Glass 版(`.glassProminent`:送出鍵、toolbar「+」)。
    func filledGlassProminentButtonStyle() -> some View {
        modifier(FilledProminentModifier(isGlass: true))
    }
}

/// prominent 樣式以 tint 為底;tint 是紅字角色，深色模式白字對它不到 4.5:1,所以改 tint 為白字填色。
private struct FilledProminentModifier: ViewModifier {
    let isGlass: Bool
    @Environment(\.hostTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let fill = whiteTextFill(theme: theme, scheme: scheme)
        if isGlass {
            content.buttonStyle(.glassProminent).tint(fill)
        } else {
            content.buttonStyle(.borderedProminent).tint(fill)
        }
    }
}
