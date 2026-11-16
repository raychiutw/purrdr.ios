import PurrdrCore
import SwiftUI

extension EnvironmentValues {
    /// 套用中的主機主題(#23);`nil` = App 自己的配色。
    @Entry var hostTheme: HostTheme?
}

extension Color {
    init(_ color: ThemeColor) {
        self.init(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
    }
}

extension ThemeAppearance {
    init(_ scheme: ColorScheme) { self = scheme == .dark ? .dark : .light }
}

extension View {
    /// 套用主機主題：tint 用主題的 accent(對比不足的外觀用 App 預設);泡泡與送出鈕的填色、終端機配色經環境值取得。
    /// 設定頁不套用(主題區永遠以預設配色繪製，任何主題都不能讓「關掉主題」變得不可讀，行為規格 F16)。
    public func hostTheme(_ theme: HostTheme?) -> some View {
        modifier(HostThemeModifier(theme: theme))
    }

    /// 套用選取中主機的主機主題，畫面存在時輪詢它(#23 × #39)。換選取中主機(或那台主機的連線重建)就換成那台的主題、重新開始輪詢。
    /// iPhone 的一疊、iPad 三欄與「在新視窗開啟」的視窗都用這個;sheet 要接在它外面才維持 App 配色。
    func selectedHostTheme(_ hosts: HostsModel) -> some View {
        let model = hosts.hostTheme
        return hostTheme(model.theme)
            .task(id: ObjectIdentifier(model)) { await model.run() }
    }

    /// 放白字的填色(使用者泡泡、送出鈕):沒有主機主題時是 tint;有主題時用主題的填色，白字對比不足就用品牌紅。
    func hostFill<S: Shape>(in shape: S) -> some View {
        modifier(HostFillModifier(shape: shape))
    }
}

private struct HostThemeModifier: ViewModifier {
    let theme: HostTheme?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .tint(theme?.app(ThemeAppearance(scheme)).tint.map(Color.init))
            .environment(\.hostTheme, theme)
    }
}

private struct HostFillModifier<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.hostTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if let theme {
            content.background(theme.app(ThemeAppearance(scheme)).fill.map(Color.init) ?? Color.accentColor, in: shape)
        } else {
            content.background(.tint, in: shape)
        }
    }
}

/// 設定頁的「主機主題」區(#23)。開關打開時先說明會在主機上寫什麼、以哪個使用者，確認才寫入。
struct HostThemeSettingsSection: View {
    let model: HostThemeModel

    var body: some View {
        Section {
            Toggle("Use Host Theme", isOn: Binding(
                get: { model.state == .on || model.state == .installing || model.isConfirming },
                set: { on in Task { on ? await model.requestTheme() : await model.turnOff() } }
            ))
            .disabled(model.isBusy)
            .accessibilityIdentifier("settings.hostTheme")
            if model.state == .on, let theme = model.theme {
                LabeledContent("herdr Theme") { Text(verbatim: theme.name) }
                    .accessibilityIdentifier("settings.hostTheme.name")
            }
            if let message = model.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Color chats and the terminal with this host’s herdr theme. Colors without enough contrast fall back to the system colors.")
        }
        .alert("Use Host Theme?", isPresented: Binding(get: { model.isConfirming }, set: { _ in })) {
            Button("Cancel", role: .cancel) { model.cancelConsent() }
            Button("Use Theme") { Task { await model.confirm() } }
                .accessibilityIdentifier("hostTheme.confirm")
        } message: {
            Text("Purrdr reads the theme in ~/.config/herdr/config.toml and adds a reference file at ~/.purrdr/theme/README.md as \(model.confirmingUser). It never changes your herdr settings. Turning this off removes the file.")
        }
    }
}

extension HostThemeModel {
    var isConfirming: Bool {
        if case .confirming = state { return true }
        return false
    }

    var confirmingUser: String {
        if case .confirming(let user) = state { return user }
        return ""
    }

    var isBusy: Bool { state == .checking || state == .installing || state == .turningOff }
}

/// 設定頁的「You should know」區(#23):已同意寫回時提供撤掉 Purrdr 的修改。
struct YouShouldKnowSettingsSection: View {
    let model: YouShouldKnowModel

    var body: some View {
        if model.isGranted {
            Section {
                Button("Undo Purrdr’s Changes to Notes", systemImage: "arrow.uturn.backward") {
                    Task { await model.undoChanges() }
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("settings.youShouldKnow.undo")
            } header: {
                Text("You Should Know")
            } footer: {
                Text("Purrdr updates Claude Code’s notes file on this host when you act on a note. Undo puts back what Purrdr changed and asks again next time.")
            }
        }
    }
}
