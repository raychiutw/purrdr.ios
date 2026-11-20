import PurrdrCore
import SwiftUI

/// 主機頁(ⓘ)的「已配對裝置」區塊(#291):列出連線配對的裝置，滑動或長按撤銷別支裝置(先確認);
/// 「這支裝置」那列改為移除主機。只有 HTTPS 主機有(`HTTPSHostConnection` 實作 `PairedDevicesManaging`)。
struct PairedDevicesSection: View {
    let model: PairedDevicesModel

    var body: some View {
        Section {
            content
        } header: {
            Text("Paired Devices")
                .foregroundStyle(.secondaryText)
        } footer: {
            if model.isReadOnly {
                Text("This device is paired read-only, so it can’t revoke devices.")
                    .foregroundStyle(.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("pairedDevices.loading")
        case .failed(let message):
            ErrorLabel(message)
                .accessibilityIdentifier("pairedDevices.error")
        case .loaded(let devices):
            ForEach(devices) { device in
                row(device)
            }
            if let error = model.revocationError {
                ErrorLabel(error)
                    .accessibilityIdentifier("pairedDevices.revokeError")
            }
        }
    }

    private func row(_ device: PairedDeviceRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: device.name)
            Text(detail(device))
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if model.revokingID == device.id { ProgressView() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pairedDevices.row.\(device.id)")
        .swipeActions {
            // 不用 destructive role:確認前列不該被移走(同主機清單的滑動刪除)。
            if model.canRevoke(device) {
                Button("Revoke", systemImage: "xmark.circle") { model.requestRevocation(of: device) }
                    .tint(.red)
            }
            if model.canRemoveHost(from: device) {
                Button("Remove Host", systemImage: "trash") { model.requestHostRemoval(from: device) }
                    .tint(.red)
                    .accessibilityIdentifier("pairedDevices.removeHost")
            }
        }
        .contextMenu {
            if model.canRevoke(device) {
                Button("Revoke…", systemImage: "xmark.circle", role: .destructive) { model.requestRevocation(of: device) }
            }
            if model.canRemoveHost(from: device) {
                Button("Remove Host…", systemImage: "trash", role: .destructive) { model.requestHostRemoval(from: device) }
            }
        }
        .accessibilityActions {
            if model.canRevoke(device) {
                Button("Revoke") { model.requestRevocation(of: device) }
            }
            if model.canRemoveHost(from: device) {
                Button("Remove Host") { model.requestHostRemoval(from: device) }
            }
        }
    }

    /// 「這支裝置 · 唯讀 · 配對於 …」。
    private func detail(_ device: PairedDeviceRecord) -> String {
        var parts: [String] = []
        if device.isCurrentDevice { parts.append(String(localized: "This Device")) }
        if device.isReadOnly { parts.append(String(localized: "Read-Only")) }
        parts.append(String(localized: "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))"))
        return parts.joined(separator: " · ")
    }

}

/// 已配對裝置的載入與撤銷確認，掛在主機頁的 `Form`:List 會把 Section 的修飾套到每一列，掛在 Section 上每列各有一個對話框。
struct PairedDevicesDialogs: ViewModifier {
    let model: PairedDevicesModel?

    func body(content: Content) -> some View {
        content
            .task { await model?.load() }
            .confirmationDialog(
                confirmationTitle, isPresented: confirmingBinding, titleVisibility: .visible, presenting: model?.confirmingRevocation
            ) { _ in
                Button("Revoke", role: .destructive) { Task { await model?.confirmRevocation() } }
                    .accessibilityIdentifier("pairedDevices.confirmRevoke")
                Button("Cancel", role: .cancel) { model?.cancelRevocation() }
            } message: { _ in
                Text("That device can’t connect to this host until it’s paired again.")
            }
    }

    private var confirmationTitle: String {
        model?.confirmingRevocation.map { String(localized: "Revoke “\($0.name)”?") } ?? ""
    }

    private var confirmingBinding: Binding<Bool> {
        Binding(get: { model?.confirmingRevocation != nil }, set: { if !$0 { model?.cancelRevocation() } })
    }
}
