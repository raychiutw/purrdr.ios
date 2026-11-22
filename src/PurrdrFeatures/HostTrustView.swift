import PurrdrCore
import SwiftUI

/// 主機身分確認(第一次以 SSH 連到這台電腦):只問信任或取消,指紋與比對方法收在「詳細資訊」。
/// 新增主機引導與主機編輯頁共用。
struct HostTrustView: View {
    let address: String
    let fingerprint: HostKeyFingerprint
    /// 主機的作業系統(決定比對指令的路徑);不知道時給 macOS／Linux 的。
    var operatingSystem: HostOperatingSystem?
    let trust: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This is the first time Purrdr connects to \(address). Trust this host?")
                        .accessibilityIdentifier("hostTrust.question")
                }
                Section {
                    DisclosureGroup("Details") {
                        Text("This host is identified by the code below.")
                            .foregroundStyle(.secondaryText)
                        Text(verbatim: fingerprint.description)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("hostTrust.fingerprint")
                        InstructionView(
                            instruction: AddHostGuideInstruction(
                                text: String(localized: "To check it yourself, run this on that computer and compare:"),
                                command: HostKeyFingerprint.compareCommand(on: operatingSystem)))
                    }
                    .accessibilityIdentifier("hostTrust.details")
                }
            }
            .navigationTitle("Trust This Host?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).accessibilityIdentifier("hostTrust.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust", action: trust).accessibilityIdentifier("hostTrust.trust")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}
