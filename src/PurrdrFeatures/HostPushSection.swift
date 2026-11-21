import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 帳號頁的「通知」區塊(#263,spec #261 原型 A):每台主機一列，開關只管那台。
///
/// 打開時才請求通知權限，確認後建立這支裝置的推播配對(外掛還沒裝才安裝);關閉只移除這支裝置的配對，
/// 最後一支裝置關閉才移除外掛(#264)。不能開的主機寫出原因。
struct HostPushSection: View {
    let pushes: [HostPush]
    /// 沒有 Purrdr Plus 時開付費牆。
    let openPlus: () -> Void
    /// 還沒配對的 HTTPS 主機：開那台主機的配對(#295)。
    var pair: (UUID) -> Void = { _ in }

    var body: some View {
        Section {
            ForEach(pushes) { push in
                HostPushRow(push: push, pair: pair)
                if push.support == .supported, push.model.state == .on {
                    HostPushKindsRow(push: push)
                }
                if push.model.canSendTestNotification {
                    HostPushTestRow(push: push)
                }
                if case .needsHostService(_, let update) = push.support {
                    HostServicePushUpdateRow(update: update)
                }
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
///
/// 還沒配對的 HTTPS 主機(#295,原型 B):開關照樣顯示但停用，副標以強調色寫「先配對這台主機 ›」,點整列開配對。
private struct HostPushRow: View {
    let push: HostPush
    let pair: (UUID) -> Void

    private var model: PushModel { push.model }

    var body: some View {
        HStack(spacing: 12) {
            HostIconBadge(push.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: push.name)
                    .accessibilityHidden(true)
                if let pairingHost {
                    Text("Pair This Host First \(Image(systemName: "chevron.forward"))")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text("Pair This Host First"))
                        .accessibilityHint(Text("Notifications can be turned on after this device pairs with the host."))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { pair(pairingHost) }
                        .accessibilityIdentifier("account.push.\(push.host.storedValue).status")
                } else {
                    status
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("account.push.\(push.host.storedValue).status")
                }
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
        // 要先配對時整列可點(開關停用，點到開關也開配對);其他列不加手勢，開關照常回應。
        .contentShape(.rect)
        .gesture(TapGesture().onEnded { if let pairingHost { pair(pairingHost) } }, isEnabled: pairingHost != nil)
        .task {
            // 只查已開啟的主機：未開啟的不為了顯示裝置數另開連線。
            if push.support == .supported, model.state == .on { await model.refreshStatus() }
        }
    }

    /// 要先配對才能開通知的主機。
    private var pairingHost: UUID? {
        guard push.support == .needsPairing, case .host(let id) = push.host else { return nil }
        return id
    }

    @ViewBuilder
    private var status: some View {
        switch push.support {
        case .needsPairing:
            // 由 `body` 另外畫成配對入口。
            EmptyView()
        case .demoHost:
            Text("The demo host can’t send notifications.")
        case .unsupported:
            Text("This host can’t send notifications.")
        case .needsHostService(let version, _):
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
                } else if push.installsViaHostService {
                    Text("Off · Installs via the host service")
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

/// 通知開著的主機:「傳送測試通知」(#328),結果以提示說明,失敗附原因。
private struct HostPushTestRow: View {
    let push: HostPush

    private var model: PushModel { push.model }

    var body: some View {
        Button {
            Task { await model.sendTestNotification() }
        } label: {
            HStack {
                Text("Send Test Notification")
                Spacer()
                if model.testNotification == .sending { ProgressView() }
            }
        }
        .disabled(model.testNotification == .sending)
        .accessibilityIdentifier("account.push.\(push.host.storedValue).test")
        .alert(resultTitle, isPresented: resultPresented) {
            Button("OK", role: .cancel) { model.dismissTestNotification() }
        } message: {
            Text(resultMessage)
        }
    }

    private var resultPresented: Binding<Bool> {
        Binding(
            get: {
                switch model.testNotification {
                case .sent, .failed: true
                case .idle, .sending: false
                }
            },
            set: { if !$0 { model.dismissTestNotification() } })
    }

    private var resultTitle: LocalizedStringKey {
        if case .failed = model.testNotification { return "Couldn’t Send Test Notification" }
        return "Test Notification Sent"
    }

    private var resultMessage: String {
        switch model.testNotification {
        case .failed(let message): message
        default: String(localized: "It should arrive on this device in a moment.")
        }
    }
}

/// 開著通知的主機可展開選要收的種類(#292);新種類加進 `PushKind` 就會多一列(主機服務只在 HTTPS 主機)。
private struct HostPushKindsRow: View {
    let push: HostPush
    @State private var isExpanded = false

    private var model: PushModel { push.model }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(PushKind.choices(installsViaHostService: push.installsViaHostService), id: \.self) { kind in
                Toggle(isOn: Binding(get: { model.kinds.contains(kind) }, set: { isOn in change(kind, to: isOn) })) {
                    Text(kind.title)
                }
                // 最後一個種類不能關：要不收通知就關閉那台主機。主機服務太舊送不出的種類不能開(已開的仍可關)。
                .disabled(model.isUpdatingKinds || model.kinds == [kind] || needsUpdate(kind))
                .accessibilityIdentifier("account.push.\(push.host.storedValue).kind.\(kind.rawValue)")
            }
            if let version = outdatedObserverVersion {
                Label("“May Be Stuck” and “Still Waiting for You” need host service \(version) or later.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("account.push.\(push.host.storedValue).kinds.needsHostService")
            } else if !push.installsViaHostService {
                Text("“May Be Stuck” and “Still Waiting for You” need the host service (HTTPS connection).")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("account.push.\(push.host.storedValue).kinds.needsHostService")
            }
        } label: {
            Text("Notification Types")
                .accessibilityIdentifier("account.push.\(push.host.storedValue).kinds")
        }
    }

    private func needsUpdate(_ kind: PushKind) -> Bool {
        !model.kinds.contains(kind) && kind.needsHostServiceUpdate(installed: push.hostServiceVersion)
    }

    /// 主機服務太舊、送不出「可能卡住」「仍在等你」時要的最低版本。
    private var outdatedObserverVersion: String? {
        guard push.installsViaHostService, PushKind.stuck.needsHostServiceUpdate(installed: push.hostServiceVersion)
        else { return nil }
        return HostServiceFeature.agentObserver.minimumVersion.description
    }

    private func change(_ kind: PushKind, to isOn: Bool) {
        Task { await model.setKind(kind, isOn: isOn) }
    }
}

extension PushKind {
    /// 帳號頁通知種類的名稱。
    var title: LocalizedStringResource {
        switch self {
        case .blocked: "Needs You"
        case .done: "Finished"
        case .stuck: "May Be Stuck"
        case .reminder: "Still Waiting for You"
        case .hostService: "Host Service"
        }
    }

    /// 那台主機可選的種類：主機服務通知與 Agent 觀察者的「可能卡住」「仍在等你」只有 HTTPS 主機(經主機服務)才有。
    public static func choices(installsViaHostService: Bool) -> [PushKind] {
        allCases.filter { installsViaHostService || ($0 != .hostService && $0.requiredHostServiceFeature == nil) }
    }
}

extension PushModel.Problem {
    /// 要在主機列下另列一行(有下一步按鈕或與主機無關);安裝失敗寫在主機列的狀態。
    var needsOwnRow: Bool {
        switch self {
        case .failed, .demoHost: false
        case .needsSubscription, .permissionDenied, .unsupportedDevice, .hostServiceOutdated, .deviceIDUnavailable, .mutedSyncFailed,
             .kindsUpdateFailed: true
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
        case .hostServiceOutdated(let update):
            HostServicePushUpdateRow(update: update)
                .accessibilityIdentifier("settings.push.problem")
        case .deviceIDUnavailable:
            Label("Couldn’t read this device’s ID from the keychain. Unlock this device and try again.", systemImage: "lock")
                .accessibilityIdentifier("settings.push.problem")
        case .failed(let message), .mutedSyncFailed(let message), .kindsUpdateFailed(let message):
            Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle") }
                .accessibilityIdentifier("settings.push.problem")
        }
    }
}

/// 主機服務太舊不能開通知：請更新主機服務，附依已安裝版本的指令(可選取、可拷貝)。
struct HostServicePushUpdateRow: View {
    let update: HostServiceUpdateCommands

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Update the host service to turn on notifications. Run this on the host:", systemImage: "arrow.down.circle")
            command(String(localized: "macOS and Linux"), update.posix)
            command(String(localized: "Windows (PowerShell)"), update.windows)
        }
        .accessibilityIdentifier("account.push.hostServiceUpdate")
    }

    private func command(_ title: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
            Text(verbatim: command)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            Button("Copy Command", systemImage: "document.on.document") { Clipboard.copy(command) }
                .buttonStyle(.borderless)
        }
    }
}

extension View {
    /// 開某台主機的通知前確認;對話框寫出主機名稱，外掛已裝時說明只新增這支裝置的配對。
    func hostPushConfirmation(_ pushes: [HostPush]) -> some View {
        let confirming = pushes.first { $0.model.isConfirming }
        return alert(
            Text("Turn On Notifications for “\(confirming?.name ?? "")”?"),
            isPresented: Binding(get: { confirming != nil }, set: { _ in }),
            presenting: confirming
        ) { push in
            Button("Install") { Task { await push.model.confirm() } }
                .accessibilityIdentifier("settings.push.install")
            Button("Cancel", role: .cancel) { push.model.cancel() }
        } message: { push in
            if push.installsViaHostService {
                if push.model.pluginAlreadyInstalled {
                    Text("The Purrdr plugin is already on this host. The host service will save a pairing key for this device in ~/.purrdr. Turning notifications off removes only this device’s pairing.")
                } else {
                    Text("The host service will run “herdr plugin install” on this host as the user running the host service, and save a pairing key for this device in ~/.purrdr. Turning notifications off removes only this device’s pairing; the plugin is removed when the last device turns off.")
                }
            } else if push.model.pluginAlreadyInstalled {
                let user = push.model.confirmingUser ?? ""
                Text("The Purrdr plugin is already on this host. Purrdr will save a pairing key for this device in ~/.purrdr as \(user). Turning notifications off removes only this device’s pairing.")
            } else {
                let user = push.model.confirmingUser ?? ""
                Text("Purrdr will run “herdr plugin install” on this host as \(user) and save a pairing key for this device in ~/.purrdr. Turning notifications off removes only this device’s pairing; the plugin is removed when the last device turns off.")
            }
        }
    }
}

extension PushModel {
    var isConfirming: Bool {
        if case .confirming = state { return true }
        return false
    }

    var confirmingUser: String? {
        if case .confirming(let user) = state { return user }
        return nil
    }
}
