import PurrdrCore
import SwiftUI

/// 主機身分確認(第一次以 SSH 連到這台電腦):只問信任或取消,指紋與比對方法收在「詳細資訊」。
/// 新增主機引導與主機編輯頁共用。
struct HostTrustView: View {
    let address: String
    let fingerprint: HostKeyFingerprint
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
                        Text("This host is identified by the code below. To check it yourself, run this on that computer and compare: ssh-keygen -lf <host key file>")
                            .foregroundStyle(.secondaryText)
                        Text(verbatim: fingerprint.description)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("hostTrust.fingerprint")
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
