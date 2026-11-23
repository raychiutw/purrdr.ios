import PurrdrAgentFeatures
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 設定 tab(#274、#393):外觀、用量顯示、鍵盤與觸覺、送出可撤回、App 鎖(#284)、支援、關於。
/// 主機主題、You should know、Codex 啟動器在各主機的主機頁(作用在那台主機)。
///
/// 會員、Purrdr Plus、通知與主機同步在帳號頁(各 tab 最右上角的帳號鈕)。
public struct SettingsView: View {
    @Bindable var model: SettingsModel
    /// 再看一次歡迎頁(#34;HIG Onboarding:跳過後在設定找得到)。
    let openWelcome: () -> Void
    /// App 鎖(#284);`nil` 時不顯示。
    let appLock: AppLock?
    /// 設定 tab 最右上角的帳號鈕(#390)。
    let account: AnyView

    /// 設定 tab:大標題「Settings」、右上只有帳號鈕。
    init(model: SettingsModel, openWelcome: @escaping () -> Void, appLock: AppLock?, account: AnyView) {
        self.model = model
        self.appLock = appLock
        self.openWelcome = openWelcome
        self.account = account
    }

    public var body: some View {
        NavigationStack {
            List {
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
                            .accessibilityIdentifier("settings.welcome")
                        Button("Rate Purrdr", systemImage: "star") { model.rateApp() }
                            .accessibilityIdentifier("settings.rate")
                        Button("Support", systemImage: "questionmark.circle") { model.openSupport() }
                            .accessibilityIdentifier("settings.support")
                        Button(
                            model.copiedDiagnostics ? "Copied" : "Copy Diagnostics",
                            systemImage: model.copiedDiagnostics ? "checkmark" : "document.on.document"
                        ) { model.copyDiagnostics() }
                            .accessibilityIdentifier("settings.copyDiagnostics")
                    } header: {
                        Text("Support")
                            .foregroundStyle(.secondaryText)
                    } footer: {
                        // 隱私揭露(複製的診斷資料包含什麼)保留;其他功能說明依原型拿掉(#276)。
                        Text("Diagnostics include the app version, iOS version, and number of hosts — never host names, addresses, account names, or conversations.")
                            .foregroundStyle(.secondaryText)
                    }

                    Section {
                        LabeledContent("Version", value: model.appVersionText)
                            .accessibilityIdentifier("settings.version")
                        Button("Privacy Policy", systemImage: "hand.raised") { model.openPrivacyPolicy() }
                            .accessibilityIdentifier("settings.privacy")
                    } header: {
                        Text("About")
                            .foregroundStyle(.secondaryText)
                    }
                }
                // 列底色要套在列的容器上(套在 List 上不會傳給列):深色的卡片才會比頁面亮(#392)。
                .listRowBackground(AppSurface.groupedRow)
            }
            .appGroupedList()
            .appPageContentWidth()
            .accessibilityIdentifier("sheet.settings")
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { account }
            }
        }
        // 使用者可能剛到系統設定加上或移除裝置密碼。
        .task { appLock?.refreshAvailability() }
    }
}

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
