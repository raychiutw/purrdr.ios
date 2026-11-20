import PurrdrCore
import SwiftUI

/// 主機狀態頁的「已配對裝置」區塊(#291):列出連線配對的裝置，滑動或長按撤銷別支裝置(先確認)。
/// 只有 HTTPS 主機有(`HTTPSHostConnection` 實作 `PairedDevicesManaging`)。
struct PairedDevicesSection: View {
    @State private var model: PairedDevicesModel

    init(host: any PairedDevicesManaging) {
        _model = State(initialValue: PairedDevicesModel(host: host))
    }

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
        .task { await model.load() }
        .confirmationDialog(
            confirmationTitle, isPresented: confirmingBinding, titleVisibility: .visible, presenting: model.confirmingRevocation
        ) { _ in
            Button("Revoke", role: .destructive) { Task { await model.confirmRevocation() } }
                .accessibilityIdentifier("pairedDevices.confirmRevoke")
            Button("Cancel", role: .cancel) { model.cancelRevocation() }
        } message: { _ in
            Text("That device can’t connect to this host until it’s paired again.")
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
            if model.canRevoke(device) {
                Button("Revoke", systemImage: "xmark.circle", role: .destructive) { model.requestRevocation(of: device) }
            }
        }
        .contextMenu {
            if model.canRevoke(device) {
                Button("Revoke…", systemImage: "xmark.circle", role: .destructive) { model.requestRevocation(of: device) }
            }
        }
        .accessibilityActions {
            if model.canRevoke(device) {
                Button("Revoke") { model.requestRevocation(of: device) }
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

    private var confirmationTitle: String {
        model.confirmingRevocation.map { String(localized: "Revoke “\($0.name)”?") } ?? ""
    }

    private var confirmingBinding: Binding<Bool> {
        Binding(get: { model.confirmingRevocation != nil }, set: { if !$0 { model.cancelRevocation() } })
    }
}
