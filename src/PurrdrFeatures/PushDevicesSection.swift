import PurrdrCore
import SwiftUI

/// 「通知裝置」子頁(#411,設計稿第 28 組):會員名下收通知的裝置，標出這支;點一列選改名或只關閉通知(不登出)。
/// 遠端關閉訂閱到期也可以,有 Purrdr Plus 才能改名。登出另一支裝置在「登入中的裝置」,與這裡分開。
///
/// 這支裝置在各主機的開關仍在「通知」區塊。對話框掛在 List 上(`pushDevicesDialogs`),不掛在 Section 上(List 會把 Section 的修飾套到每一列)。
struct PushDevicesView: View {
    let model: PushDevicesModel
    /// 有效的 Purrdr Plus 才能改名。
    let canRename: Bool

    var body: some View {
        List {
            Section {
                if !model.hasLoaded {
                    // 整頁第一次載入:骨架(#626)。
                    RowsSkeleton(identifier: "account.pushDevices.loading")
                } else if model.devices.isEmpty, model.problem == nil {
                    // 系統空狀態(#626)。
                    ContentUnavailableView(
                        "No Notification Devices", systemImage: "bell.slash",
                        description: Text("No devices receive notifications yet."))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("account.pushDevices.empty")
                }
                ForEach(model.devices) { device in
                    PushDeviceRow(device: device, isBusy: model.busyDeviceIDs.contains(device.id), canRename: canRename) {
                        model.pendingAction = .rename(device)
                    } turnOff: {
                        model.pendingAction = .turnOff(device)
                    }
                }
                if let problem = model.problem {
                    // 頁內錯誤一律紅色三角說明(#626)。
                    ErrorLabel(problem.text, area: "PushDevices")
                        .accessibilityIdentifier("account.pushDevices.problem")
                }
            } footer: {
                Text("Tap a device to rename it or turn off its notifications without signing it out. Turning off a device stops its notifications from every host, even if it’s lost.")
                    .foregroundStyle(.secondaryText)
            }
        }
        .appGroupedList()
        .accessibilityIdentifier("account.pushDevices")
        .navigationTitle("Notification Devices")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
        .pushDevicesDialogs(model)
    }
}

extension View {
    /// 「通知裝置」的改名與關閉對話框。
    func pushDevicesDialogs(_ model: PushDevicesModel) -> some View {
        modifier(PushDevicesDialogs(model: model))
    }

    /// 帳號頁:會員在(開通後)與這支裝置的通知開關變了(`notifyingHostNames`)就重讀清單,讓入口列的數量是新的。
    func pushDevicesLoading(_ model: PushDevicesModel?, notifyingHostNames: [String]) -> some View {
        task(id: PushDevicesLoadTrigger(isActive: model != nil, notifyingHostNames: notifyingHostNames)) { await model?.load() }
    }
}

private struct PushDevicesLoadTrigger: Equatable {
    var isActive: Bool
    var notifyingHostNames: [String]
}

private struct PushDevicesDialogs: ViewModifier {
    let model: PushDevicesModel
    @State private var newName = ""

    private var renaming: PushDevice? {
        if case .rename(let device) = model.pendingAction { return device }
        return nil
    }

    private var turningOff: PushDevice? {
        if case .turnOff(let device) = model.pendingAction { return device }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: renaming?.id) { _, id in
                if id != nil { newName = renaming?.name ?? "" }
            }
            .alert(
                Text("Rename Device"),
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { model.pendingAction = nil } }),
                presenting: renaming
            ) { device in
                TextField("Device Name", text: $newName)
                    .accessibilityIdentifier("account.pushDevices.name")
                Button("Save") { Task { await model.rename(device, to: newName) } }
                    .disabled(PushDeviceIdentity.validName(newName) == nil)
                    .accessibilityIdentifier("account.pushDevices.save")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Up to 64 characters.")
            }
            .confirmationDialog(
                Text("Turn Off Notifications for “\(turningOff?.displayName ?? "")”?"),
                isPresented: Binding(get: { turningOff != nil }, set: { if !$0 { model.pendingAction = nil } }),
                titleVisibility: .visible,
                presenting: turningOff
            ) { device in
                Button("Turn Off Notifications", role: .destructive) { Task { await model.turnOff(device) } }
                    .accessibilityIdentifier("account.pushDevices.confirmTurnOff")
            } message: { device in
                if device.isCurrent {
                    Text("This device stops receiving notifications from all hosts. You can turn hosts back on under Notifications.")
                } else {
                    Text("That device stops receiving notifications from all hosts. To get them again, turn notifications back on from that device.")
                }
            }
    }
}

/// 一支裝置：圖示、名稱(這支標「This Device」)、型號、開了幾台主機、最後使用;整列點一下選改名或關閉通知。
private struct PushDeviceRow: View {
    let device: PushDevice
    let isBusy: Bool
    let canRename: Bool
    let rename: () -> Void
    let turnOff: () -> Void

    var body: some View {
        content
            // 左滑與選單同一組動作(#626)。不用 destructive role:關閉要先確認,確認前列不該被移走(0.52.1 閃退的教訓)。
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !isBusy {
                    Button("Turn Off Notifications", systemImage: "bell.slash", action: turnOff)
                        .tint(.red)
                        .accessibilityIdentifier("account.pushDevices.swipeTurnOff")
                    if canRename {
                        Button("Rename", systemImage: "pencil", action: rename)
                            .accessibilityIdentifier("account.pushDevices.swipeRename")
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isBusy {
            HStack { label; ProgressView() }
        } else {
            Menu {
                if canRename {
                    Button("Rename…", systemImage: "pencil", action: rename)
                        .accessibilityIdentifier("account.pushDevices.rename")
                }
                Button("Turn Off Notifications…", systemImage: "bell.slash", role: .destructive, action: turnOff)
                    .accessibilityIdentifier("account.pushDevices.turnOff")
            } label: {
                HStack {
                    label
                    // 會開選單的列不用 >(#619):列尾是 ⋯。
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondaryText)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(device.displayName), \(accessibilitySummary)"))
            .accessibilityHint(Text("Shows options for this device"))
            .accessibilityIdentifier("account.pushDevice.\(device.id)")
        }
    }

    private var label: some View {
        HStack(spacing: 12) {
            Image(systemName: device.model == .iPad ? "ipad" : "iphone")
                .font(.title3)
                .foregroundStyle(.secondaryText)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // 這支裝置的標示放在名稱列尾(系統 `LabeledContent`),不自畫小膠囊。
                LabeledContent {
                    if device.isCurrent {
                        Text("This Device")
                    }
                } label: {
                    Text(verbatim: device.displayName)
                }
                details
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44)
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if device.isCurrent { parts.append(String(localized: "This Device")) }
        parts.append(String(localized: "Hosts: \(device.hostCount)"))
        return parts.joined(separator: ", ")
    }

    private var details: Text {
        let lastUsed = device.lastRegisteredAt.formatted(.relative(presentation: .named))
        if let model = device.model {
            return Text("\(model.rawValue) · Hosts: \(device.hostCount) · Last used \(lastUsed)")
        }
        return Text("Hosts: \(device.hostCount) · Last used \(lastUsed)")
    }
}

extension PushDevicesModel.Problem {
    /// 頁內錯誤的說明文字。
    var text: String {
        switch self {
        case .needsSubscription: String(localized: "Renaming devices needs Purrdr Plus.")
        case .failed(let message): message
        }
    }
}

extension PushDevice {
    /// 舊版 app 註冊的裝置沒有名稱，顯示「未命名裝置」。
    var displayName: String {
        name ?? String(localized: "Unnamed Device")
    }
}
