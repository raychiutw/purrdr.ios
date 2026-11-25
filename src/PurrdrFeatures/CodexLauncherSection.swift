import PurrdrCore
import SwiftUI

/// 設定頁的「Codex 啟動器」區段(行為規格 §4.2,ADR-0002:每台主機個別同意、說明改什麼與以哪個使用者、可完整移除)。
/// 【未實測】說明文字照實標示。
struct CodexLauncherSection: View {
    let model: CodexLauncherModel

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.isOn },
                set: { on in Task { on ? await model.request() : await model.turnOff() } }
            )) {
                HStack {
                    Text("Codex Launcher")
                    if isBusy {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isBusy)
            .accessibilityIdentifier("settings.codexLauncher")
            if let message = model.message {
                ErrorLabel(message, area: "CodexLauncher")
                    .font(.footnote)
                    .accessibilityIdentifier("settings.codexLauncher.message")
            }
        } header: {
            Text("Codex")
                .foregroundStyle(.secondaryText)
        } footer: {
            Text("Untested. Adds a small Codex launcher on the selected host so each Codex chat shows up correctly. Turning it off removes everything Purrdr added.")
                .foregroundStyle(.secondaryText)
        }
        .alert("Install Codex Launcher?", isPresented: Binding(get: { isConfirming }, set: { _ in })) {
            // 按鈕動作前 binding 會先被設成 false:取消與確認都交給按鈕處理(#22 地雷)。
            Button("Install") { Task { await model.confirm() } }
            Button("Cancel", role: .cancel) { model.cancelConsent() }
        } message: {
            Text("Purrdr will add a small Codex launcher on this host, as “\(confirmingUser)”. It changes nothing else. You can turn it off here at any time.")
        }
    }

    private var isBusy: Bool {
        switch model.state {
        case .checking, .installing, .removing: true
        case .off, .confirming, .on: false
        }
    }

    private var isConfirming: Bool {
        if case .confirming = model.state { return true }
        return false
    }

    private var confirmingUser: String {
        if case .confirming(let user) = model.state { return user }
        return ""
    }
}
