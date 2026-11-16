import SwiftUI

/// 設定頁的「通知」區(行為規格 F14、F15;HIG:通知設定可在 app 內管理)。
///
/// 開關對選取中主機：打開時才請求通知權限，確認後經 SSH 安裝主機外掛並建立推播配對;關閉時移除。
struct PushSettingsSection: View {
    let model: PushModel
    /// 沒有 Purrdr Plus 時開付費牆。
    let openPlus: () -> Void

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { isOnOrPending }, set: { change(to: $0) })) {
                Text("Notify When an Agent Needs You")
            }
            .disabled(isWorking)
            .accessibilityIdentifier("settings.push")
            if isWorking {
                ProgressView(workingText)
                    .accessibilityIdentifier("settings.push.working")
            }
            if let problem = model.problem {
                problemRow(problem)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Purrdr adds a small herdr plugin to this host. When an agent needs you, the host tells Purrdr’s server, which notifies this device. Notifications show only the workspace name — never what the agent said. Notifications from Windows hosts are best-effort.")
        }
        .alert(
            "Install the Purrdr Plugin?",
            isPresented: Binding(get: { confirmingUser != nil }, set: { _ in }),
            presenting: confirmingUser
        ) { _ in
            Button("Install") { Task { await model.confirm() } }
                .accessibilityIdentifier("settings.push.install")
            Button("Cancel", role: .cancel) { model.cancel() }
        } message: { user in
            Text("Purrdr will run “herdr plugin install” on this host as \(user) and save a pairing key in ~/.purrdr. Turning notifications off removes both.")
        }
    }

    private var isOnOrPending: Bool {
        switch model.state {
        case .on, .turningOn, .confirming: true
        case .off, .checking, .turningOff: false
        }
    }

    private var isWorking: Bool {
        switch model.state {
        case .checking, .turningOn, .turningOff: true
        case .off, .on, .confirming: false
        }
    }

    private var workingText: LocalizedStringKey {
        model.state == .turningOff ? "Removing the plugin…" : "Setting up notifications…"
    }

    private var confirmingUser: String? {
        if case .confirming(let user) = model.state { return user }
        return nil
    }

    private func change(to isOn: Bool) {
        Task {
            if isOn {
                await model.requestOn()
            } else {
                await model.turnOff()
            }
        }
    }

    @ViewBuilder
    private func problemRow(_ problem: PushModel.Problem) -> some View {
        switch problem {
        case .demoHost:
            Label("Choose your own host first. The demo host can’t send notifications.", systemImage: "info.circle")
                .accessibilityIdentifier("settings.push.problem")
        case .needsSubscription:
            VStack(alignment: .leading, spacing: 8) {
                Label("Notifications need Purrdr Plus.", systemImage: "bell.badge")
                Button("See Purrdr Plus", action: openPlus)
                    .accessibilityIdentifier("settings.push.plus")
            }
            .accessibilityIdentifier("settings.push.problem")
        case .permissionDenied:
            VStack(alignment: .leading, spacing: 8) {
                Label("Notifications are off for Purrdr in iOS Settings.", systemImage: "bell.slash")
                Button("Open Settings") { model.openSystemSettings() }
                    .accessibilityIdentifier("settings.push.openSettings")
            }
            .accessibilityIdentifier("settings.push.problem")
        case .unsupportedDevice(let detail):
            Label("This device can’t receive notifications. \(detail)", systemImage: "exclamationmark.triangle")
                .accessibilityIdentifier("settings.push.problem")
        case .failed(let message):
            Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle") }
                .accessibilityIdentifier("settings.push.problem")
        }
    }
}
