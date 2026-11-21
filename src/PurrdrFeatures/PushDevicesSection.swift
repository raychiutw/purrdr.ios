import PurrdrCore
import SwiftUI

/// 帳號頁的「通知裝置」區塊(#266):會員名下收通知的裝置，標出這支;每支可遠端關閉(訂閱到期也可以),有 Purrdr Plus 才能改名。
///
/// 這支裝置在各主機的開關仍在「通知」區塊。對話框與重讀清單掛在帳號頁的 List(`pushDevicesDialogs`),
/// 不掛在 Section 上(List 會把 Section 的修飾套到每一列)。
struct PushDevicesSection: View {
    let model: PushDevicesModel
    /// 有效的 Purrdr Plus 才能改名。
    let canRename: Bool

    var body: some View {
        Section {
            if model.hasLoaded, model.devices.isEmpty, model.problem == nil {
                Text("No devices receive notifications yet.")
                    .foregroundStyle(.secondaryText)
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
                Label {
                    switch problem {
                    case .needsSubscription: Text("Renaming devices needs Purrdr Plus.")
                    case .failed(let message): Text(verbatim: message)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .accessibilityIdentifier("account.pushDevices.problem")
            }
        } header: {
            Text("Notification Devices")
                .foregroundStyle(.secondaryText)
        } footer: {
            Text("Turning off a device stops its notifications from every computer, even if it’s lost. Each computer’s leftover pairing is removed the next time it tries to notify.")
                .foregroundStyle(.secondaryText)
        }
    }
}

extension View {
    /// 「通知裝置」的改名與關閉對話框;這支裝置的通知開關變了(`notifyingHostNames`)就重讀清單。
    func pushDevicesDialogs(_ model: PushDevicesModel?, notifyingHostNames: [String]) -> some View {
        modifier(PushDevicesDialogs(model: model, notifyingHostNames: notifyingHostNames))
    }
}

private struct PushDevicesDialogs: ViewModifier {
    let model: PushDevicesModel?
    let notifyingHostNames: [String]
    @State private var newName = ""

    /// 區塊出現(開通後)或這支裝置的通知開關變了就重讀。
    private struct LoadTrigger: Equatable {
        var isActive: Bool
        var notifyingHostNames: [String]
    }

    private var renaming: PushDevice? {
        if case .rename(let device) = model?.pendingAction { return device }
        return nil
    }

    private var turningOff: PushDevice? {
        if case .turnOff(let device) = model?.pendingAction { return device }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .task(id: LoadTrigger(isActive: model != nil, notifyingHostNames: notifyingHostNames)) { await model?.load() }
            .onChange(of: renaming?.id) { _, id in
                if id != nil { newName = renaming?.name ?? "" }
            }
            .alert(
                Text("Rename Device"),
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { model?.pendingAction = nil } }),
                presenting: renaming
            ) { device in
                TextField("Device Name", text: $newName)
                    .accessibilityIdentifier("account.pushDevices.name")
                Button("Save") { Task { await model?.rename(device, to: newName) } }
                    .disabled(PushDeviceIdentity.validName(newName) == nil)
                    .accessibilityIdentifier("account.pushDevices.save")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Up to 64 characters.")
            }
            .confirmationDialog(
                Text("Turn Off Notifications for “\(turningOff?.displayName ?? "")”?"),
                isPresented: Binding(get: { turningOff != nil }, set: { if !$0 { model?.pendingAction = nil } }),
                titleVisibility: .visible,
                presenting: turningOff
            ) { device in
                Button("Turn Off Notifications", role: .destructive) { Task { await model?.turnOff(device) } }
                    .accessibilityIdentifier("account.pushDevices.confirmTurnOff")
            } message: { device in
                if device.isCurrent {
                    Text("This device stops receiving notifications from all computers. You can turn computers back on under Notifications.")
                } else {
                    Text("That device stops receiving notifications from all computers. To get them again, turn notifications back on from that device.")
                }
            }
    }
}

/// 一支裝置：圖示、名稱(這支標「This Device」)、型號、開了幾台主機、最後使用;右側是改名與關閉的選單。
private struct PushDeviceRow: View {
    let device: PushDevice
    let isBusy: Bool
    let canRename: Bool
    let rename: () -> Void
    let turnOff: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.model == .iPad ? "ipad" : "iphone")
                .font(.title3)
                .foregroundStyle(.secondaryText)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: device.displayName)
                    if device.isCurrent {
                        Text("This Device")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                details
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("account.pushDevice.\(device.id)")
            if isBusy {
                ProgressView()
            } else {
                Menu {
                    if canRename {
                        Button("Rename…", systemImage: "pencil", action: rename)
                            .accessibilityIdentifier("account.pushDevices.rename")
                    }
                    Button("Turn Off Notifications…", systemImage: "bell.slash", role: .destructive, action: turnOff)
                        .accessibilityIdentifier("account.pushDevices.turnOff")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Actions for \(device.displayName)"))
                .accessibilityIdentifier("account.pushDevice.\(device.id).actions")
            }
        }
    }

    private var details: Text {
        let lastUsed = device.lastRegisteredAt.formatted(.relative(presentation: .named))
        if let model = device.model {
            return Text("\(model.rawValue) · Computers: \(device.hostCount) · Last used \(lastUsed)")
        }
        return Text("Computers: \(device.hostCount) · Last used \(lastUsed)")
    }
}

extension PushDevice {
    /// 舊版 app 註冊的裝置沒有名稱，顯示「未命名裝置」。
    var displayName: String {
        name ?? String(localized: "Unnamed Device")
    }
}
