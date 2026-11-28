import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 帳號頁的「通知」區塊(#263,spec #261 原型 A):每台主機一列，開關只管那台。
///
/// 打開時才請求通知權限，確認後建立這支裝置的推播配對(外掛還沒裝才安裝);關閉只移除這支裝置的配對，
/// 最後一支裝置關閉才移除外掛(#264)。不能開的主機寫出原因。
struct HostPushSection: View {
    let pushes: [HostPush]
    /// 今日推播用量(#677);讀不到時是 `nil`,不顯示這一列。
    var usage: PushDailyUsage?
    /// 還沒配對的 HTTPS 主機：開那台主機的配對(#295)。
    var pair: (UUID) -> Void = { _ in }

    var body: some View {
        Section {
            if let usage { PushUsageRow(usage: usage) }
            ForEach(pushes) { push in
                HostPushRow(push: push, pair: pair)
                if push.support == .supported, push.model.state == .on {
                    HostPushKindsRow(push: push)
                }
                if push.model.canSendTestNotification, push.supportsTestNotification {
                    HostPushTestRow(push: push)
                }
                if case .needsHostService(_, let update) = push.support {
                    HostServicePushUpdateRow(update: update)
                }
                if push.support == .supported, let problem = push.model.problem, problem.needsOwnRow {
                    PushProblemRow(problem: problem, model: push.model)
                }
            }
        } header: {
            Text("Notifications")
                .foregroundStyle(.secondaryText)
        } footer: {
            Text("Purrdr adds a small helper to each host you turn on. When an agent needs you, this device gets a notification. Notifications show only the workspace name, never what the agent said. On Windows hosts, notifications may be delayed.")
                .foregroundStyle(.secondaryText)
        }
        .task {
            // 種類清單與配對以後台為準(#705):有開著通知的主機時讀一次(所有主機共用同一份)。
            if let push = pushes.first(where: { $0.support == .supported && $0.model.state == .on }) {
                await push.model.refreshKindSettings()
            }
        }
    }
}

/// 一台主機的通知列：圖示、名稱、狀態與開關。VoiceOver 念「主機名稱，通知已開啟／未開啟」。
///
/// 還沒配對的 HTTPS 主機(#295,原型 B):開關照樣顯示但停用，副標是「先配對這台主機」按鈕(系統 `.borderless` 按鈕),點它開配對。
struct HostPushRow: View {
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
                    // 系統按鈕(#623):不用手勢加 trait 模擬按鈕。
                    Button("Pair This Host First") { pair(pairingHost) }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                        .accessibilityHint(Text("Notifications can be turned on after this device pairs with the host."))
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
                // errorLabel:exempt 需求提示,不是失敗
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
                if case .failed(let shown) = model.problem {
                    ErrorLabel(String(localized: "\(shown.text) Tap the switch to try again."), area: "HostPush", error: shown.descriptor)
                } else if model.otherDevices > 0 {
                    Text("Off · Other devices here: \(model.otherDevices)")
                } else if push.installsViaHostService {
                    Text("Off")
                } else {
                    Text("Off")
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

/// 通知開著的主機:「傳送測試通知」(#328),結果直接顯示在列上(#625,不彈 alert),失敗附原因。
struct HostPushTestRow: View {
    let push: HostPush

    private var model: PushModel { push.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            switch model.testNotification {
            case .sent:
                Label("Sent. It should arrive on this device in a moment.", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("account.push.\(push.host.storedValue).test.result")
            case .failed(let shown):
                ErrorLabel(shown.text, area: "PushTest", error: shown.descriptor)
                    .font(.footnote)
                    .accessibilityIdentifier("account.push.\(push.host.storedValue).test.result")
            case .idle, .sending:
                EmptyView()
            }
        }
    }
}

/// 開著通知的主機可展開選要收的種類(#292);種類照後台的清單畫(#705),後台加了種類就多一列。
private struct HostPushKindsRow: View {
    let push: HostPush
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            PushKindToggles(push: push)
        } label: {
            Text("Notification Types")
                .accessibilityIdentifier("account.push.\(push.host.storedValue).kinds")
        }
    }
}

/// 一台主機的通知種類開關(帳號頁與主機通知頁共用):名稱與說明用後台給的(依手機語言);
/// 這台主機不能開的種類(要裝主機服務、主機服務或外掛太舊)停用並說明原因,已開著的仍可關。最後一個種類不能關。
struct PushKindToggles: View {
    let push: HostPush

    private var model: PushModel { push.model }

    private var context: PushKindContext {
        PushKindContext(installsViaHostService: push.installsViaHostService, hostServiceVersion: push.hostServiceVersion)
    }

    var body: some View {
        ForEach(model.kindChoices(context: context)) { choice in
            let isOn = model.kinds.contains(choice.kind)
            Toggle(isOn: Binding(get: { isOn }, set: { on in change(choice.kind, to: on) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: choice.title)
                    if !choice.details.isEmpty {
                        Text(verbatim: choice.details)
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                    }
                    if let reason = PushKindReason.text(choice.availability) {
                        reason
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                            .accessibilityIdentifier("account.push.\(push.host.storedValue).kind.\(choice.kind.rawValue).reason")
                    }
                }
            }
            .disabled(model.isUpdatingKinds || (isOn && model.kinds == [choice.kind]) || (!isOn && !choice.availability.isAvailable))
            .accessibilityIdentifier("account.push.\(push.host.storedValue).kind.\(choice.kind.rawValue)")
        }
    }

    private func change(_ kind: PushKind, to isOn: Bool) {
        Task { await model.setKind(kind, isOn: isOn) }
    }
}

/// 種類不能開的原因(畫面文字)。
enum PushKindReason {
    static func text(_ availability: PushKindAvailability) -> Text? {
        switch availability {
        case .available, .unsupportedConnection: nil
        case .needsHostService: Text("Needs the host service (HTTPS connection).")
        case .needsHostServiceUpdate(let minimum): Text("Needs host service \(minimum.description) or later.")
        case .needsPluginUpdate(let minimum): Text("Needs notification helper \(minimum.description) or later.")
        }
    }
}

extension PushModel.Problem {
    /// 要在主機列下另列一行(有下一步按鈕或與主機無關);安裝失敗寫在主機列的狀態。
    var needsOwnRow: Bool {
        switch self {
        case .failed, .demoHost: false
        case .needsSignIn, .permissionDenied, .unsupportedDevice, .hostServiceOutdated, .deviceIDUnavailable, .mutedSyncFailed,
             .kindsUpdateFailed: true
        }
    }
}

/// 推播開不起來的原因與下一步。
struct PushProblemRow: View {
    let problem: PushModel.Problem
    let model: PushModel
    /// 帳號頁已在登入畫面時不需要;主機頁給開登入的動作。
    var openAccount: (() -> Void)?

    var body: some View {
        switch problem {
        case .demoHost:
            Label("Choose your own host first. The demo host can’t send notifications.", systemImage: "info.circle")
                .accessibilityIdentifier("settings.push.problem")
        case .needsSignIn:
            VStack(alignment: .leading, spacing: 8) {
                Label("Sign in to use notifications.", systemImage: "person.crop.circle")
                if let openAccount {
                    Button("Sign In", action: openAccount)
                        .listAction()
                        .accessibilityIdentifier("settings.push.signIn")
                }
            }
            .accessibilityIdentifier("settings.push.problem")
        case .permissionDenied:
            VStack(alignment: .leading, spacing: 8) {
                Label("Notifications are off for Purrdr in iOS Settings.", systemImage: "bell.slash")
                Button("Open Settings") { model.openSystemSettings() }
                    .listAction()
                    .accessibilityIdentifier("settings.push.openSettings")
            }
            .accessibilityIdentifier("settings.push.problem")
        case .unsupportedDevice(let detail):
            ErrorLabel(String(localized: "This device can’t receive notifications. \(detail.text)"), area: "HostPush", error: detail.descriptor)
                .accessibilityIdentifier("settings.push.problem")
        case .hostServiceOutdated(let update):
            HostServicePushUpdateRow(update: update)
                .accessibilityIdentifier("settings.push.problem")
        case .deviceIDUnavailable(let shown):
            ErrorLabel(shown.text, area: "HostPush", error: shown.descriptor)
                .accessibilityIdentifier("settings.push.problem")
        case .failed(let message), .mutedSyncFailed(let message), .kindsUpdateFailed(let message):
            ErrorLabel(message.text, area: "HostPush", error: message.descriptor)
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
                .listAction()
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
            Button("Install") {
                Task {
                    await push.model.confirm(kindContext: PushKindContext(
                        installsViaHostService: push.installsViaHostService, hostServiceVersion: push.hostServiceVersion))
                }
            }
                .accessibilityIdentifier("settings.push.install")
            Button("Cancel", role: .cancel) { push.model.cancel() }
        } message: { push in
            if push.installsViaHostService {
                if push.model.pluginAlreadyInstalled {
                    Text("The Purrdr notification helper is already on this host. The host service will add this device to it. Turning notifications off removes only this device.")
                } else {
                    Text("The host service will install a small notification helper on this host. Turning notifications off removes only this device; the helper is removed when the last device turns off.")
                }
            } else if push.model.pluginAlreadyInstalled {
                let user = push.model.confirmingUser ?? ""
                Text("The Purrdr notification helper is already on this host. Purrdr will add this device to it, as \(user). Turning notifications off removes only this device.")
            } else {
                let user = push.model.confirmingUser ?? ""
                Text("Purrdr will install a small notification helper on this host, as \(user). Turning notifications off removes only this device; the helper is removed when the last device turns off.")
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

/// 今日推播用量一列(#677):「今日 23／100 則」加歸零時間;到達上限時改成「今日已達上限」(警示色,不只靠顏色)。
struct PushUsageRow: View {
    let usage: PushDailyUsage

    var body: some View {
        let text = PushUsageText(usage)
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: text.summary)
                .foregroundStyle(usage.isLimitReached ? Color.orange : Color.primary)
                .accessibilityIdentifier("account.push.usage.summary")
            Spacer()
            Text(verbatim: text.resetNote)
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
                .accessibilityIdentifier("account.push.usage.reset")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account.push.usage")
    }
}
