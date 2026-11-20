import PurrdrAgentFeatures
import SwiftUI

/// 帳號頁的「通知」區塊(#263,spec #261 原型 A):每台主機一列，開關只管那台。
///
/// 打開時才請求通知權限，確認後建立這支裝置的推播配對(外掛還沒裝才安裝);關閉只移除這支裝置的配對，
/// 最後一支裝置關閉才移除外掛(#264)。不能開的主機寫出原因。
struct HostPushSection: View {
    let pushes: [HostPush]
    /// 沒有 Purrdr Plus 時開付費牆。
    let openPlus: () -> Void

    var body: some View {
        Section {
            ForEach(pushes) { push in
                HostPushRow(push: push)
                if push.support == .supported, let problem = push.model.problem, problem.needsOwnRow {
                    PushProblemRow(problem: problem, model: push.model, openPlus: openPlus)
                }
            }
        } header: {
            Text("Notifications")
                .foregroundStyle(.secondaryText)
        } footer: {
            Text("Purrdr adds a small herdr plugin to each host you turn on. When an agent needs you, the host tells Purrdr’s server, which notifies this device. Notifications show only the workspace name — never what the agent said. Notifications from Windows hosts are best-effort.")
                .foregroundStyle(.secondaryText)
        }
    }
}

/// 一台主機的通知列：圖示、名稱、狀態與開關。VoiceOver 念「主機名稱，通知已開啟／未開啟」。
private struct HostPushRow: View {
    let push: HostPush

    private var model: PushModel { push.model }

    var body: some View {
        HStack(spacing: 12) {
            HostIconBadge(push.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: push.name)
                    .accessibilityHidden(true)
                status
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("account.push.\(push.host.storedValue).status")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: Binding(get: { isOnOrPending }, set: { change(to: $0) })) {
                Text(verbatim: push.name)
            }
            .labelsHidden()
            .disabled(push.support != .supported || isWorking)
            .accessibilityLabel(Text(verbatim: push.name))
            .accessibilityValue(isOnOrPending ? Text("Notifications On") : Text("Notifications Off"))
            .accessibilityIdentifier("account.push.\(push.host.storedValue)")
        }
        .task {
            // 只查已開啟的主機：未開啟的不為了顯示裝置數另開連線。
            if push.support == .supported, model.state == .on { await model.refreshStatus() }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch push.support {
        case .demoHost:
            Text("The demo host can’t send notifications.")
        case .needsHostService(let version):
            Label("Needs host service \(version) or later", systemImage: "exclamationmark.triangle")
        case .supported:
            switch model.state {
            case .on:
                if model.otherDevices > 0 {
                    Text("Notifications On · Other devices here: \(model.otherDevices)")
                } else {
                    Text("Notifications On")
                }
            case .turningOff:
                Text("Turning off notifications…")
            case .checking, .confirming, .turningOn:
                Text("Setting up notifications…")
            case .off:
                if case .failed(let message) = model.problem {
                    Label {
                        Text("\(message) Tap the switch to try again.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                } else if model.otherDevices > 0 {
                    Text("Off · Other devices here: \(model.otherDevices)")
                } else {
                    Text("Off · Installs over SSH")
                }
            }
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

    private func change(to isOn: Bool) {
        Task {
            if isOn {
                await model.requestOn()
            } else {
                await model.turnOff()
            }
        }
    }
}

extension PushModel.Problem {
    /// 要在主機列下另列一行(有下一步按鈕或與主機無關);安裝失敗寫在主機列的狀態。
    var needsOwnRow: Bool {
        switch self {
        case .failed, .demoHost: false
        case .needsSubscription, .permissionDenied, .unsupportedDevice: true
        }
    }
}

/// 推播開不起來的原因與下一步。
struct PushProblemRow: View {
    let problem: PushModel.Problem
    let model: PushModel
    let openPlus: () -> Void

    var body: some View {
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

extension View {
    /// 開某台主機的通知前確認;對話框寫出主機名稱，外掛已裝時說明只新增這支裝置的配對。
    func hostPushConfirmation(_ pushes: [HostPush]) -> some View {
        let confirming = pushes.first { $0.model.confirmingUser != nil }
        return alert(
            Text("Turn On Notifications for “\(confirming?.name ?? "")”?"),
            isPresented: Binding(get: { confirming != nil }, set: { _ in }),
            presenting: confirming
        ) { push in
            Button("Install") { Task { await push.model.confirm() } }
                .accessibilityIdentifier("settings.push.install")
            Button("Cancel", role: .cancel) { push.model.cancel() }
        } message: { push in
            let user = push.model.confirmingUser ?? ""
            if push.model.pluginAlreadyInstalled {
                Text("The Purrdr plugin is already on this host. Purrdr will save a pairing key for this device in ~/.purrdr as \(user). Turning notifications off removes only this device’s pairing.")
            } else {
                Text("Purrdr will run “herdr plugin install” on this host as \(user) and save a pairing key for this device in ~/.purrdr. Turning notifications off removes only this device’s pairing; the plugin is removed when the last device turns off.")
            }
        }
    }
}

extension PushModel {
    var confirmingUser: String? {
        if case .confirming(let user) = state { return user }
        return nil
    }
}
