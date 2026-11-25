import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 通知頁(主機 tab 的子頁,#392):這台主機的通知開關與要收的種類。
///
/// 還沒配對的 HTTPS 主機說明要先配對;沒登入開登入、沒有 Purrdr Plus 開付費牆。
struct HostNotificationsPage: View {
    let hosts: HostsModel
    let host: HostSelection
    let signedIn: Bool
    let openAccount: () -> Void
    let openPlus: () -> Void
    let pair: (UUID) -> Void

    private var push: HostPush? { hosts.hostPushes.first { $0.host == host } }

    var body: some View {
        List {
            Group {
                if let push {
                    switchSection(push)
                    if push.support == .supported, push.model.state == .on {
                        kindsSection(push)
                        if push.model.canSendTestNotification, push.supportsTestNotification {
                            Section { HostPushTestRow(push: push) }
                        }
                    }
                    if case .needsHostService(_, let update) = push.support {
                        Section { HostServicePushUpdateRow(update: update) }
                    }
                    if push.support == .supported, let problem = push.model.problem, problem.needsOwnRow {
                        Section { problemRow(problem, push) }
                    }
                }
            }
            // 列底色要套在列的容器上(套在 List 上不會傳給列):深色的卡片才會比頁面亮(#392)。
            .listRowBackground(AppSurface.groupedRow)
        }
        .appGroupedList()
        .navigationTitle("Notifications")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationSubtitle(hosts.name(of: host))
        .accessibilityIdentifier("hosts.notifications.page")
        .hostPushConfirmation(push.map { [$0] } ?? [])
        .task {
            // 只查已開啟的主機:未開啟的不為了顯示裝置數另開連線。
            if let push, push.support == .supported, push.model.state == .on { await push.model.refreshStatus() }
        }
    }

    // MARK: - 開關

    private func switchSection(_ push: HostPush) -> some View {
        let model = push.model
        return Section {
            if case .host(let id) = push.host, push.support == .needsPairing {
                Button {
                    pair(id)
                } label: {
                    HostRowLabel(title: "Pair This Host First", subtitle: "Notifications can be turned on after this device pairs with the host.")
                }
                .listAction()
                .accessibilityIdentifier("hosts.notifications.pair")
            } else {
                Toggle(isOn: Binding(get: { isOnOrPending(model) }, set: { change(model, to: $0) })) {
                    Text("Notifications for This Host")
                }
                .disabled(push.support != .supported || isWorking(model))
                .accessibilityValue(isOnOrPending(model) ? Text("Notifications On") : Text("Notifications Off"))
                .accessibilityIdentifier("hosts.notifications.toggle")
                if let status = statusText(push) {
                    status
                        .font(.footnote)
                        .foregroundStyle(.secondaryText)
                        .accessibilityIdentifier("hosts.notifications.status")
                }
            }
        } footer: {
            Text("Notifications show only the workspace name, never what the agent said. On Windows hosts, notifications may be delayed.")
                .foregroundStyle(.secondaryText)
        }
    }

    private func statusText(_ push: HostPush) -> Text? {
        switch push.support {
        case .demoHost: return Text("The demo host can’t send notifications.")
        case .unsupported: return Text("This host can’t send notifications.")
        case .needsHostService(let version, _): return Text("Needs host service \(version) or later")
        case .needsPairing: return nil
        case .supported:
            switch push.model.state {
            case .turningOff: return Text("Turning off notifications…")
            case .checking, .confirming, .turningOn: return Text("Setting up notifications…")
            case .on:
                return push.model.otherDevices > 0 ? Text("Other devices here: \(push.model.otherDevices)") : nil
            case .off:
                if case .failed(let message) = push.model.problem { return Text("\(message) Tap the switch to try again.") }
                return nil
            }
        }
    }

    private func isOnOrPending(_ model: PushModel) -> Bool {
        switch model.state {
        case .on, .turningOn, .confirming: true
        case .off, .checking, .turningOff: false
        }
    }

    private func isWorking(_ model: PushModel) -> Bool {
        switch model.state {
        case .checking, .turningOn, .turningOff: true
        case .off, .on, .confirming: false
        }
    }

    private func change(_ model: PushModel, to isOn: Bool) {
        Task { if isOn { await model.requestOn() } else { await model.turnOff() } }
    }

    // MARK: - 種類

    private func kindsSection(_ push: HostPush) -> some View {
        let model = push.model
        return Section {
            ForEach(PushKind.choices(installsViaHostService: push.installsViaHostService), id: \.self) { kind in
                Toggle(
                    isOn: Binding(
                        get: { model.kinds.contains(kind) },
                        set: { isOn in Task { await model.setKind(kind, isOn: isOn) } })
                ) {
                    Text(kind.title)
                }
                // 最後一個種類不能關:要不收通知就關閉這台主機。主機服務太舊送不出的種類不能開(已開的仍可關)。
                .disabled(model.isUpdatingKinds || model.kinds == [kind] || needsUpdate(kind, push))
                .accessibilityIdentifier("account.push.\(push.host.storedValue).kind.\(kind.rawValue)")
            }
            if let version = outdatedObserverVersion(push) {
                Label("“May Be Stuck” and “Still Waiting for You” need host service \(version) or later.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            } else if !push.installsViaHostService {
                Text("“May Be Stuck” and “Still Waiting for You” need the host service (HTTPS connection).")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Notification Types")
                .foregroundStyle(.secondaryText)
        } footer: {
            Text("Keep at least one. To get none, turn off notifications for this host. Devices that get notifications are managed in your account.")
                .foregroundStyle(.secondaryText)
        }
    }

    private func needsUpdate(_ kind: PushKind, _ push: HostPush) -> Bool {
        !push.model.kinds.contains(kind) && kind.needsHostServiceUpdate(installed: push.hostServiceVersion)
    }

    private func outdatedObserverVersion(_ push: HostPush) -> String? {
        guard push.installsViaHostService, PushKind.stuck.needsHostServiceUpdate(installed: push.hostServiceVersion) else { return nil }
        return HostServiceFeature.agentObserver.minimumVersion.description
    }

    // MARK: - 問題

    @ViewBuilder
    private func problemRow(_ problem: PushModel.Problem, _ push: HostPush) -> some View {
        if case .needsSubscription = problem, !signedIn {
            // 沒登入:先登入(帳號頁沒登入時直接是登入頁)。
            VStack(alignment: .leading, spacing: 8) {
                Label("Sign in to use notifications.", systemImage: "person.crop.circle")
                Button("Sign In", action: openAccount)
                    .listAction()
                    .accessibilityIdentifier("hosts.notifications.signIn")
            }
            .accessibilityIdentifier("settings.push.problem")
        } else {
            PushProblemRow(problem: problem, model: push.model, openPlus: openPlus)
        }
    }
}

/// 這台主機的設定頁(主機 tab 的子頁,#392):主機主題、You should know、Codex 啟動器與用量擷取,作用在這台主機。
struct HostSettingsPage: View {
    let hosts: HostsModel
    let hostID: UUID
    let settings: HostSettings
    let isReadOnly: Bool

    var body: some View {
        List {
            Group {
                HostThemeSettingsSection(model: settings.hostTheme)
                YouShouldKnowSettingsSection(model: settings.youShouldKnow)
                CodexLauncherSection(model: settings.codexLauncher)
                Section {
                    // 用量擷取的啟用與還原(經同意修改主機上 Claude Code 的 status line 設定,可完整還原)。
                    NavigationLink {
                        PlanUsageScreen(model: hosts.screens.planUsage(host: .host(hostID), agent: .claudeCode))
                    } label: {
                        HostRowLabel(title: "Usage Capture")
                    }
                    .accessibilityIdentifier("hosts.settings.usageCapture")
                } footer: {
                    Text("These features write settings on the host. Each can be fully put back.")
                        .foregroundStyle(.secondaryText)
                }
            }
            // 列底色要套在列的容器上(套在 List 上不會傳給列):深色的卡片才會比頁面亮(#392)。
            .listRowBackground(AppSurface.groupedRow)
        }
        .appGroupedList()
        .navigationTitle("Settings for This Host")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationSubtitle(hosts.name(of: .host(hostID)))
        .accessibilityIdentifier("hosts.settings.page")
    }
}

/// 已配對裝置頁(主機 tab 的子頁,#392):列出連線配對的裝置,滑動或長按撤銷別支裝置;「這支裝置」那列移除主機。
struct HostPairedDevicesPage: View {
    let model: PairedDevicesModel

    var body: some View {
        List {
            Group {
                PairedDevicesSection(model: model)
            }
            // 列底色要套在列的容器上(套在 List 上不會傳給列):深色的卡片才會比頁面亮(#392)。
            .listRowBackground(AppSurface.groupedRow)
        }
        .appGroupedList()
        .navigationTitle("Paired Devices")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.load() }
        .modifier(PairedDevicesDialogs(model: model))
        .accessibilityIdentifier("hosts.pairedDevices.page")
    }
}

/// 主機的 Agent 設定頁(#477,設計稿 HostAgents):逐一開關這台主機裝了哪些 Agent。
/// 開著的才顯示用量、才能在這台主機新增聊天;Agent 列表不受影響。
struct HostAgentSettingsPage: View {
    let hosts: HostsModel
    let hostID: UUID
    @State private var model: HostAgentSettingsModel

    init(hosts: HostsModel, hostID: UUID, model: @autoclosure () -> HostAgentSettingsModel) {
        self.hosts = hosts
        self.hostID = hostID
        _model = State(wrappedValue: model())
    }

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(model.rows) { row in
                        Toggle(isOn: Binding(get: { row.isEnabled }, set: { model.setEnabled(row.agent, $0) })) {
                            HStack(spacing: 12) {
                                AgentKindAvatar(kind: AgentKind(rawKind: row.agent.canonicalName))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: row.name)
                                    if let detection = detectionText(row.detection) {
                                        detection
                                            .font(.footnote)
                                            .foregroundStyle(.secondaryText)
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("hosts.agents.\(row.agent.canonicalName)")
                    }
                } header: {
                    Text("Turned-on Agents show their usage and can start new chats on this host.")
                        .textCase(nil)
                        .foregroundStyle(.secondaryText)
                } footer: {
                    Text("When you add a host, Purrdr finds the Agents on it. You can also turn on one it didn’t find.")
                        .foregroundStyle(.secondaryText)
                }
            }
            // 列底色要套在列的容器上(套在 List 上不會傳給列):深色的卡片才會比頁面亮(#392)。
            .listRowBackground(AppSurface.groupedRow)
        }
        .appGroupedList()
        .navigationTitle("Agent")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationSubtitle(hosts.name(of: .host(hostID)))
        .accessibilityIdentifier("hosts.agents.page")
        .task { await model.load() }
    }

    private func detectionText(_ detection: HostAgentSettingsModel.Detection) -> Text? {
        switch detection {
        case .detected: Text("Found on this host")
        case .notDetected: Text("Not found")
        case .checking, .unknown: nil
        }
    }
}
