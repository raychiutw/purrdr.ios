import PurrdrAgentFeatures
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 帳號 sheet 帶進來的設定內容(#503):設定 tab 已移除,設定併進帳號與設定 sheet 的第一層。
struct AccountSettings {
    let model: SettingsModel
    /// 再看一次歡迎頁(#34;HIG Onboarding:跳過後在設定找得到)。
    let openWelcome: () -> Void
    /// App 鎖(#284);`nil` 時不顯示。
    let appLock: AppLock?
}

/// 設定的各個段落(#274、#393、#503):外觀、用量顯示、鍵盤與觸覺、送出可撤回、App 鎖(#284)、支援、關於。
/// 放在帳號 sheet 的 `List` 裡(登入與未登入的第一層都有)。
/// 主機主題、You should know、Codex 啟動器在各主機的主機頁(作用在那台主機)。
struct SettingsSections: View {
    @Bindable var model: SettingsModel
    let openWelcome: () -> Void
    let appLock: AppLock?

    init(_ settings: AccountSettings) {
        self.model = settings.model
        self.openWelcome = settings.openWelcome
        self.appLock = settings.appLock
    }

    var body: some View {
        Group {
            Section {
                Picker("Appearance", selection: $model.appearance) {
                    Text("Automatic").tag(AppearancePreference.automatic)
                    Text("Light").tag(AppearancePreference.light)
                    Text("Dark").tag(AppearancePreference.dark)
                }
                // 選項攤開成勾選列(#313)。
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("settings.appearance")
            } header: {
                Text("Appearance")
                    .foregroundStyle(.secondaryText)
            } footer: {
                Text("Automatic follows your device’s Light or Dark setting.")
                    .foregroundStyle(.secondaryText)
            }

            // 方案用量顯示已用或剩餘(#393;全域,方案用量畫面沿用)。
            Section {
                Picker("Usage Display", selection: $model.planUsageDisplay) {
                    Text("Used").tag(PlanUsageModel.Display.used)
                    Text("Remaining").tag(PlanUsageModel.Display.remaining)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("settings.planUsageDisplay")
            } header: {
                Text("Usage Display")
                    .foregroundStyle(.secondaryText)
            }

            Section {
                Toggle("Return Key Sends", isOn: $model.returnSends)
                    .accessibilityIdentifier("settings.returnSends")
                Toggle("Haptics", isOn: $model.hapticsEnabled)
                    .accessibilityIdentifier("settings.haptics")
            } header: {
                Text("Keyboard and Haptics")
                    .foregroundStyle(.secondaryText)
            }

            // 送出可撤回(#300):0–10 秒,0 為關閉。
            Section {
                Stepper(value: $model.undoSendSeconds, in: UndoSendSettings.range) {
                    LabeledContent("Undo Send") {
                        Text(model.undoSendSeconds == 0 ? String(localized: "Off") : String(localized: "\(model.undoSendSeconds) s"))
                            .monospacedDigit()
                    }
                }
                .accessibilityValue(Text(model.undoSendSeconds == 0
                    ? String(localized: "Off") : String(localized: "\(model.undoSendSeconds) seconds")))
                .accessibilityIdentifier("settings.undoSend")
            } footer: {
                Text("After you send, the message waits this long so you can undo it.")
                    .foregroundStyle(.secondaryText)
            }

            if let appLock {
                AppLockSettingsSection(lock: appLock)
            }

            Section {
                Button("Show Welcome", systemImage: "hand.wave") { openWelcome() }
                    .listAction()
                    .accessibilityIdentifier("settings.welcome")
                Button("Rate Purrdr", systemImage: "star") { model.rateApp() }
                    .listAction()
                    .accessibilityIdentifier("settings.rate")
                Button("Support", systemImage: "questionmark.circle") { model.openSupport() }
                    .listAction()
                    .accessibilityIdentifier("settings.support")
                Button(
                    model.copiedDiagnostics ? "Copied" : "Copy Diagnostics",
                    systemImage: model.copiedDiagnostics ? "checkmark" : "document.on.document"
                ) { model.copyDiagnostics() }
                    .listAction()
                    .accessibilityIdentifier("settings.copyDiagnostics")
            } header: {
                Text("Support")
                    .foregroundStyle(.secondaryText)
            } footer: {
                // 隱私揭露(複製的診斷資料包含什麼)保留;其他功能說明依原型拿掉(#276)。
                Text("Diagnostics include the app version, iOS version, and number of hosts — never host names, addresses, account names, or conversations.")
                    .foregroundStyle(.secondaryText)
            }

            if model.hasHitchRecorder {
                HitchLogSection(model: model)
            }

            Section {
                LabeledContent("Version", value: model.appVersionText)
                    .accessibilityIdentifier("settings.version")
                Button("Privacy Policy", systemImage: "hand.raised") { model.openPrivacyPolicy() }
                    .listAction()
                    .accessibilityIdentifier("settings.privacy")
            } header: {
                Text("About")
                    .foregroundStyle(.secondaryText)
            }
        }
        // 列底色要套在列的容器上(套在 List 上不會傳給列):深色的卡片才會比頁面亮(#392)。
        .listRowBackground(AppSurface.groupedRow)
        // 使用者可能剛到系統設定加上或移除裝置密碼。
        .task { appLock?.refreshAvailability() }
    }
}

/// 「診斷記錄」:閃退(一律記)與「操作記錄」開關控制的聊天捲動卡頓、顯示給使用者的錯誤,只存在這支手機,使用者可分享給開發者、整份清除。
struct HitchLogSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Section {
            Toggle("Operation Log", isOn: $model.recordsHitches)
                .accessibilityIdentifier("settings.hitchLog")
            Button("Share Diagnostic Log", systemImage: "square.and.arrow.up") {
                Task {
                    guard let url = await model.exportHitchLog() else { return }
                    #if os(iOS)
                    SystemSharePresenter.present(url)
                    #endif
                }
            }
            .listAction()
            .accessibilityIdentifier("settings.hitchLog.share")
            Button("Clear Records", systemImage: "trash", role: .destructive) {
                Task { await model.clearHitchLog() }
            }
            .accessibilityIdentifier("settings.hitchLog.clear")
        } header: {
            Text("Diagnostic Log")
                .foregroundStyle(.secondaryText)
        } footer: {
            // 只在按了分享卻沒有記錄時說一句(不是功能說明)。
            if model.hitchLogIsEmpty {
                Text("Nothing recorded yet.")
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("settings.hitchLog.empty")
            }
        }
    }
}

#if os(iOS)
/// 系統分享選單(分享檔案)。直接由目前最上層的 view controller 呈現,不當成 SwiftUI sheet 的內容:
/// 包在 `.sheet` 裡的 `UIActivityViewController` 會讓下層的帳號與設定 sheet 一起被收掉(0.51.1 實機回報)。
@MainActor
enum SystemSharePresenter {
    static func present(_ url: URL) {
        guard let top = topViewController() else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
#endif

/// 平台服務的系統實作。
@MainActor
public final class SystemPlatformServices: PlatformServices {
    public init() {}

    public func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    public func copy(_ text: String) {
        Clipboard.copy(text)
    }
}
