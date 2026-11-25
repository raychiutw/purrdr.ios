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
            // 整頁第一次載入:骨架(#626)。
            RowsSkeleton(identifier: "pairedDevices.loading")
        case .failed(let message):
            ErrorLabel(message, area: "PairedDevicesSection")
                .accessibilityIdentifier("pairedDevices.error")
        case .loaded(let devices):
            ForEach(devices) { device in
                row(device)
            }
            if let error = model.revocationError {
                ErrorLabel(error, area: "PairedDevicesSection")
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
        // confirmationDialog:anchor 撤銷由列的滑動或長按選單觸發,對話框錨定在那一列
        .confirmationDialog(
            Text("Revoke “\(device.name)”?"),
            isPresented: Binding(
                get: { model.confirmingRevocation?.id == device.id },
                set: { if !$0, model.confirmingRevocation?.id == device.id { model.cancelRevocation() } }),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) { Task { await model.confirmRevocation(of: device) } }
                .accessibilityIdentifier("pairedDevices.confirmRevoke")
            Button("Cancel", role: .cancel) { model.cancelRevocation() }
        } message: {
            Text("That device can’t connect to this host until it’s paired again.")
        }
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

/// 已配對裝置的載入,掛在主機頁的 `Form`。撤銷確認對話框掛在各列上(錨定在那一列,#625)。
struct PairedDevicesDialogs: ViewModifier {
    let model: PairedDevicesModel?

    func body(content: Content) -> some View {
        content
            .task { await model?.load() }
    }
}
