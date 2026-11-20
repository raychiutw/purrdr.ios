import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

extension View {
    /// 機密偵測的說明 sheet(#302,原型 `#t302-b`):送出的訊息像含有密鑰時從底部升起。
    /// 下滑關閉等同「返回編輯」。
    func secretCheckSheet(_ check: SecretCheck?) -> some View {
        sheet(item: Binding(
            get: { check?.review },
            set: { if $0 == nil { check?.returnToEditing() } }
        )) { review in
            if let check {
                SecretCheckSheet(review: review, check: check)
            }
        }
    }
}

/// 逐項列出偵測到的類別與第幾行(不顯示內容本身),說明只在本機檢查;「返回編輯」(主要)與「仍要送出」。
struct SecretCheckSheet: View {
    let review: SecretReview
    let check: SecretCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Message May Contain a Secret")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("secretCheck.title")
            }
            .padding(.top, 24)
            VStack(spacing: 0) {
                ForEach(Array(review.findings.enumerated()), id: \.offset) { index, finding in
                    if index > 0 { Divider().padding(.leading, 44) }
                    findingRow(finding)
                }
            }
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
            Text("Checked only on this device. Nothing was sent anywhere.")
                .font(.footnote)
                .foregroundStyle(.secondaryText)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button {
                    check.returnToEditing()
                } label: {
                    Text("Back to Editing").frame(maxWidth: .infinity)
                }
                .filledProminentButtonStyle()
                .controlSize(.large)
                .accessibilityIdentifier("secretCheck.backToEditing")
                Button {
                    check.sendAnyway()
                } label: {
                    Text("Send Anyway").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .foregroundStyle(.primary)
                .controlSize(.large)
                .accessibilityIdentifier("secretCheck.sendAnyway")
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("secretCheck.sheet")
    }

    private func findingRow(_ finding: SecretFinding) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .foregroundStyle(.secondaryText)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(Self.name(of: finding.kind))
            Spacer()
            Text("Line \(finding.line)")
                .foregroundStyle(.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("secretCheck.finding.\(finding.kind.rawValue)")
    }

    /// 類別的顯示名稱(可攜核心不放顯示字串)。
    static func name(of kind: SecretKind) -> String {
        switch kind {
        case .privateKey: String(localized: "Private key")
        case .gitHubToken: String(localized: "GitHub token")
        case .skKey: String(localized: "sk- key")
        case .awsKey: String(localized: "AWS key")
        case .slackToken: String(localized: "Slack token")
        case .googleAPIKey: String(localized: "Google API key")
        case .jwt: String(localized: "JWT")
        case .password: String(localized: "Password (password=)")
        }
    }
}
