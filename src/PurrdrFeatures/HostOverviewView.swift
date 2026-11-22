import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 主機 tab 的單台主機總頁內容(#392):連線狀態、用量、主機服務、這台主機的入口、移除。
struct HostOverviewView: View {
    let hosts: HostsModel
    let overview: HostOverview
    let plus: SubscriptionModel?
    let openPlus: () -> Void
    let statusCache: HostStatusCache
    let actionError: String?
    let removeHost: (UUID) -> Void
    let removeDemo: () -> Void
    let openAddHost: () -> Void
    let openRoute: (HostRoute) -> Void

    @Environment(\.usageSections) private var usage

    private var hostID: UUID? {
        if case .host(let id) = overview.host { return id }
        return nil
    }

    var body: some View {
        List {
            Group {
                HostStatusRow(overview: overview, retry: retry, pair: pair, update: { if let hostID { openRoute(.edit(hostID)) } })
                if overview.showsUsage, let usage {
                    UsageSectionContainer(host: overview.host, agents: PlanUsageAgent.allCases, context: usage, scopedTitle: false)
                        .id(overview.host)
                }
                if overview.showsHostService, let hostID, let models = statusCache.models(for: hostID, hosts: hosts) {
                    hostService(hostID, models)
                }
                if overview.status == .demo {
                    demoSections
                } else {
                    thisHostSection
                    if let hostID {
                        Section {
                            Button("Remove Host", role: .destructive) { removeHost(hostID) }
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("hosts.delete")
                        }
                    }
                }
                if let message = actionError ?? hosts.loadError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                            .accessibilityIdentifier("hosts.error")
                    }
                }
            }
            // 列底色要套在列的容器上(套在 List 上不會傳給列):深色的卡片才會比頁面亮(#392、設計稿第 15 組)。
            .listRowBackground(AppSurface.groupedRow)
        }
        .appGroupedList()
        .accessibilityIdentifier("sheet.hosts")
        .refreshable {
            if let hostID { await statusCache.models(for: hostID, hosts: hosts)?.refresh() }
            await hosts.refreshOverviewFacts()
        }
        .task {
            await hosts.checkHostServiceVersions()
            await hosts.refreshOverviewFacts()
        }
    }

    // MARK: - 主機服務(已配對的 HTTPS 主機)

    @ViewBuilder
    private func hostService(_ id: UUID, _ models: HostStatusModels) -> some View {
        if let service = models.hostService {
            HostServiceSection(model: service)
        }
        // 有新版時:說明怎麼在主機上更新(#198;太舊不能從 app 管理的主機只有這個入口,能管理的也可以照指令自己更新)。
        if let row = hosts.rows.first(where: { $0.id == id }), row.hostServiceUpdate != nil, row.hostServiceUpdateCommands != nil {
            Section {
                NavigationLink(value: HostRoute.hostServiceUpdate(id)) {
                    Label("Update the Host Service on \(row.title)", systemImage: "arrow.up.circle")
                }
                .accessibilityIdentifier("hosts.update.\(id.uuidString)")
            }
        }
        if let devices = models.pairedDevices {
            Section {
                NavigationLink(value: HostRoute.pairedDevices(id)) {
                    LabeledContent("Paired Devices") {
                        if case .loaded(let records) = devices.state { Text("\(records.count)") }
                    }
                }
                .task { await devices.load() }
                .accessibilityIdentifier("hosts.pairedDevices")
            }
        }
    }

    // MARK: - 這台主機

    private var pushState: HostPush? { hosts.hostPushes.first { $0.host == overview.host } }

    private var thisHostSection: some View {
        Section {
            if showsNotifications, let push = pushState {
                notificationsRow(push)
            }
            if overview.showsLoginShell {
                if case .offline = overview.status {
                    HostRowLabel(title: "Login Shell", subtitle: "Available once connected")
                        .foregroundStyle(.secondaryText)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityIdentifier("hosts.tool.loginShell.unavailable")
                } else {
                    NavigationLink(value: HostRoute.loginShell) {
                        HostRowLabel(title: "Login Shell")
                    }
                    .accessibilityIdentifier("hosts.tool.loginShell")
                }
            }
            if let hostID, showsShare {
                NavigationLink(value: HostRoute.share(hostID)) {
                    HostRowLabel(title: "Share…")
                }
                .accessibilityIdentifier("hosts.share")
            }
            if let hostID, showsSettings {
                if overview.status == .readOnly {
                    HostRowLabel(title: "Settings for This Host", subtitle: "Read-only devices can’t change this")
                        .foregroundStyle(.secondaryText)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityIdentifier("hosts.settings.readOnly")
                } else {
                    NavigationLink(value: HostRoute.hostSettings(hostID)) {
                        HostRowLabel(title: "Settings for This Host")
                    }
                    .accessibilityIdentifier("hosts.settings")
                }
            }
            if let hostID {
                NavigationLink(value: HostRoute.edit(hostID)) {
                    HostRowLabel(title: "Edit Host")
                }
                .accessibilityIdentifier("hosts.edit")
            }
        } header: {
            Text("This Host")
                .foregroundStyle(.secondaryText)
        }
    }

    /// 通知(#405):有 Plus 才能進去開關;沒有 Plus 顯示鎖定與原因,點了開付費牆,不誤導成已開啟。
    @ViewBuilder
    private func notificationsRow(_ push: HostPush) -> some View {
        if plus?.isPlusActive == true || push.support == .needsPairing {
            NavigationLink(value: HostRoute.notifications) {
                HostRowLabel(title: "Notifications", detail: notificationDetail(push))
            }
            .accessibilityIdentifier("hosts.notifications")
        } else {
            Button(action: openPlus) {
                // 設計稿第 28 組:標題下一行寫原因,鎖頭在列的最右邊。
                HStack {
                    HostRowLabel(title: "Notifications", subtitle: "Needs Purrdr Plus")
                    Spacer(minLength: 8)
                    Image(systemName: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondaryText)
                }
            }
            .foregroundStyle(.primary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Notifications"))
            .accessibilityValue(Text("Locked. Needs Purrdr Plus"))
            .accessibilityHint(Text("Opens Purrdr Plus."))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("hosts.tool.notifications.locked")
            // 剛開 app 時還沒讀過訂閱:讀一次(沒登入不連網路)。
            .task { await plus?.refresh() }
        }
    }

    private var showsNotifications: Bool {
        switch overview.status {
        case .demo, .needsPairing, .herdrTooOld: false
        case .connecting, .online, .readOnly, .offline: true
        }
    }

    private var showsShare: Bool {
        switch overview.status {
        case .demo, .needsPairing, .herdrTooOld: false
        case .connecting, .online, .readOnly, .offline: overview.canShare
        }
    }

    private var showsSettings: Bool {
        switch overview.status {
        case .demo, .needsPairing, .herdrTooOld, .offline: false
        case .connecting, .online, .readOnly: overview.hasHostSettings
        }
    }

    /// 通知列右側:開著顯示收的種類(「需要你、完成」),否則說明為什麼不能開。
    private func notificationDetail(_ push: HostPush) -> Text {
        switch push.support {
        case .needsPairing: Text("Pair This Host First")
        case .demoHost, .unsupported: Text("Not Available")
        case .needsHostService: Text("Update Host Service")
        case .supported:
            switch push.model.state {
            case .on: Text(verbatim: PushKinds.summary(push.model.kinds, installsViaHostService: push.installsViaHostService))
            case .checking, .confirming, .turningOn: Text("Setting Up…")
            case .off, .turningOff: Text("Off")
            }
        }
    }

    // MARK: - 範例主機

    @ViewBuilder
    private var demoSections: some View {
        Section {
            Button {
                openAddHost()
            } label: {
                HostRowLabel(title: "Add Your Own Host")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hosts.demo.addOwn")
            // 設計稿(#392)範例主機沒有登入 Shell;刻意保留:App Review 要能開 Demo 的模擬終端機(#434,App 內建、不連真電腦)。
            if overview.showsLoginShell {
                NavigationLink(value: HostRoute.loginShell) {
                    HostRowLabel(title: "Login Shell")
                }
                .accessibilityIdentifier("hosts.tool.loginShell")
            }
        } header: {
            Text("This Host")
                .foregroundStyle(.secondaryText)
        }
        Section {
            Button("Remove Demo Host", role: .destructive, action: removeDemo)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("hosts.demo.remove")
        }
    }

    // MARK: - 動作

    private func retry() {
        hosts.agentList.list(for: overview.host)?.retry()
    }

    private func pair() {
        if let hostID { openRoute(.pairGuide(hostID)) }
    }
}

/// 「通知種類」的摘要文字(「需要你、完成」)。
enum PushKinds {
    static func summary(_ kinds: Set<PushKind>, installsViaHostService: Bool) -> String {
        let titles = PushKind.choices(installsViaHostService: installsViaHostService)
            .filter { kinds.contains($0) }
            .map { String(localized: $0.title) }
        return ListFormatter.localizedString(byJoining: titles)
    }
}

/// 總頁上一列的標題與右側說明(或標題下的副標)。
struct HostRowLabel: View {
    let title: LocalizedStringKey
    var detail: Text?
    var subtitle: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                if let detail {
                    Spacer(minLength: 8)
                    detail
                        .foregroundStyle(.secondaryText)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
    }
}

/// 連線狀態列(設計稿 Host):圓點加標題與一行說明,需要處理時下面有動作鈕。
struct HostStatusRow: View {
    let overview: HostOverview
    let retry: () -> Void
    let pair: () -> Void
    let update: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    indicator
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        title
                            .font(.headline)
                        subtitle
                            .font(.footnote)
                            .foregroundStyle(.secondaryText)
                    }
                }
                action
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hosts.status")
        }
    }

    // MARK: 標題

    @ViewBuilder
    private var indicator: some View {
        switch overview.status {
        case .online, .readOnly, .demo:
            Circle().fill(StatusTone.accent.style).frame(width: 8, height: 8).accessibilityHidden(true)
        case .connecting:
            ProgressView().controlSize(.small)
        case .offline, .needsPairing, .herdrTooOld:
            // 狀態用圖示加文字，不只靠顏色。
            Image(systemName: ErrorLabel.symbolName)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        }
    }

    private var title: Text {
        switch overview.status {
        case .demo: Text("Demo Host")
        case .connecting: Text("Connecting…")
        case .online: Text("Online")
        case .readOnly: Text("Online · View Only")
        case .offline: Text("Can’t Reach This Host")
        case .needsPairing: Text("Not Paired on This Device")
        case .herdrTooOld(let version): Text("herdr \(version) Is Too Old")
        }
    }

    private var subtitle: Text {
        switch overview.status {
        case .demo: Text("Try Purrdr with sample conversations. Nothing connects to a computer.")
        case .connecting, .online: Text(verbatim: connectionText)
        case .readOnly: Text("This device can only look. It can’t send or answer.")
        case .offline(let message, let last):
            if let last {
                Text("\(message) · Last Connected \(last, format: .dateTime.hour().minute())")
            } else {
                Text(verbatim: message)
            }
        case .needsPairing: Text("This host came from another device. Enter its pairing code to use it here.")
        case .herdrTooOld: Text("Purrdr needs herdr 0.9.5 or later.")
        }
    }

    private var connectionText: String { overview.connectionSummary }

    // MARK: 動作

    @ViewBuilder
    private var action: some View {
        switch overview.status {
        case .offline:
            Button("Try Again", action: retry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("hosts.status.retry")
        case .needsPairing:
            Button("Enter Pairing Code", action: pair)
                .filledProminentButtonStyle()
                .accessibilityIdentifier("hosts.status.pair")
        case .herdrTooOld:
            if overview.connection?.usesHostService == true {
                Text("Update herdr on the host.")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            } else {
                Button("Update herdr", action: update)
                    .filledProminentButtonStyle()
                    .accessibilityIdentifier("hosts.status.updateHerdr")
            }
        case .demo, .connecting, .online, .readOnly:
            EmptyView()
        }
    }
}

extension HostOverview {
    /// 「Tailscale SSH · herdr 0.9.6」「HTTPS · buildbox.tail1234.ts.net · herdr 0.9.6」。
    /// herdr 版本逐台顯示在這裡(設定 tab 不再顯示,#419);HTTPS 主機也要顯示。
    package var connectionSummary: String {
        var parts: [String] = []
        switch connection {
        case .tailscaleSSH: parts.append(String(localized: "Tailscale SSH"))
        case .openSSH: parts.append(String(localized: "OpenSSH"))
        case .https: parts.append(String(localized: "HTTPS"))
        case nil: break
        }
        if let address {
            parts.append(address.replacingOccurrences(of: "https://", with: ""))
        }
        if let herdrVersion {
            parts.append("herdr \(herdrVersion)")
        }
        return parts.joined(separator: " · ")
    }
}
