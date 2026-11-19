import PurrdrCore
import SwiftUI

extension View {
    /// 填色底的主要按鈕(`.borderedProminent`):底是主色填色、字是主色上的字色(有主機主題時用主題填色與白字)。
    func filledProminentButtonStyle() -> some View {
        modifier(FilledProminentModifier(isGlass: false))
    }

    /// 同 `filledProminentButtonStyle()`,Liquid Glass 版(`.glassProminent`:送出鍵、toolbar「+」)。
    func filledGlassProminentButtonStyle() -> some View {
        modifier(FilledProminentModifier(isGlass: true))
    }
}

/// prominent 樣式的字預設是白色，深色模式白字對主色不到 4.5:1,所以字色改 `onProminentFill`。
private struct FilledProminentModifier: ViewModifier {
    let isGlass: Bool

    func body(content: Content) -> some View {
        if isGlass {
            content.buttonStyle(.glassProminent).tint(ProminentFillStyle()).foregroundStyle(.onProminentFill)
        } else {
            content.buttonStyle(.borderedProminent).tint(ProminentFillStyle()).foregroundStyle(.onProminentFill)
        }
    }
}

/// 承載字的填色(ADR-0011):主機主題的填色(白字對比已檢查),沒有就用主色 `AccentColor`。
struct ProminentFillStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.hostTheme?.app(ThemeAppearance(environment.colorScheme)).fill.map(Color.init) ?? Color.accentColor
    }
}

/// `ProminentFillStyle` 上的字與符號：主機主題填色用白字，主色用 `onAccent`。
struct OnProminentFillStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.hostTheme?.app(ThemeAppearance(environment.colorScheme)).fill == nil ? .onAccent : .white
    }
}

extension ShapeStyle where Self == ProminentFillStyle {
    /// 承載字的填色：主色，或主機主題的填色。
    static var prominentFill: ProminentFillStyle { ProminentFillStyle() }
}

extension ShapeStyle where Self == OnProminentFillStyle {
    /// `prominentFill` 上的字與符號。
    static var onProminentFill: OnProminentFillStyle { OnProminentFillStyle() }
}

/// 淡主色底:tint(主色或主機主題 accent)加不透明度，上面的字與符號用 `.tint`。
struct SoftAccentFillStyle: ShapeStyle {
    /// 固定不透明度;`nil` 是淺色 12%、深色 16%(主機圖示的圓形底)。
    var opacity: Double?

    func resolve(in environment: EnvironmentValues) -> Color {
        let tint = environment.hostTheme?.app(ThemeAppearance(environment.colorScheme)).tint.map(Color.init) ?? Color.accentColor
        return tint.opacity(opacity ?? (environment.colorScheme == .dark ? 0.16 : 0.12))
    }
}

extension ShapeStyle where Self == SoftAccentFillStyle {
    /// 淡主色底(主機圖示的圓形底，不承載字)。
    static var softAccentFill: SoftAccentFillStyle { SoftAccentFillStyle() }

    /// 指定不透明度的淡主色底;承載字時不透明度要有對比測試。
    static func softAccentFill(opacity: Double) -> SoftAccentFillStyle { SoftAccentFillStyle(opacity: opacity) }
}
