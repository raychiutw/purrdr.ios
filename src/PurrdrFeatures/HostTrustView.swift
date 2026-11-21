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
                    Text("This is the first time Purrdr connects to \(address). Trust this computer?")
                        .accessibilityIdentifier("hostTrust.question")
                }
                Section {
                    DisclosureGroup("Details") {
                        Text("This computer identifies itself with this key. To check it yourself, run ssh-keygen -lf on a host key file on that computer and compare.")
                            .foregroundStyle(.secondaryText)
                        Text(verbatim: fingerprint.description)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("hostTrust.fingerprint")
                    }
                    .accessibilityIdentifier("hostTrust.details")
                }
            }
            .navigationTitle("Trust This Computer?")
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
