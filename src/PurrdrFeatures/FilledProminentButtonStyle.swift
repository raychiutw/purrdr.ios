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
        environment.hostThemeColor(\.fill)
    }
}

/// `ProminentFillStyle` 上的字與符號：主機主題填色用白字，主色用 `onAccent`。
struct OnProminentFillStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.hostAppColors?.fill == nil ? .onAccent : .white
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
        environment.hostThemeColor(\.tint).opacity(opacity ?? (environment.colorScheme == .dark ? 0.16 : 0.12))
    }
}

extension ShapeStyle where Self == SoftAccentFillStyle {
    /// 淡主色底(主機圖示的圓形底，不承載字)。
    static var softAccentFill: SoftAccentFillStyle { SoftAccentFillStyle() }

    /// 指定不透明度的淡主色底;承載字時不透明度要有對比測試。
    static func softAccentFill(opacity: Double) -> SoftAccentFillStyle { SoftAccentFillStyle(opacity: opacity) }
}

extension EnvironmentValues {
    /// 主機主題在目前深淺色的 App 配色;沒有主機主題時是 `nil`。
    fileprivate var hostAppColors: AppThemeColors? { hostTheme?.app(ThemeAppearance(colorScheme)) }

    /// 主機主題的某個顏色，沒有就用主色 `AccentColor`。
    fileprivate func hostThemeColor(_ color: KeyPath<AppThemeColors, ThemeColor?>) -> Color {
        hostAppColors?[keyPath: color].map(Color.init) ?? Color.accentColor
    }
}

extension Color {
    /// app 的主色(emerald,ADR-0011),不跟主機主題(#477):頂端的主機下拉與「+」用它,各 tab 一致。
    static var appAccent: Color { .accentColor }

    /// 承載文字的主色(跟著 tint 與主機主題;#329):AttributedString 的指令著色拿不到 `.tint` 樣式，用它取代直接寫 accentColor。
    static var commandText: Color { .accentColor }
}
