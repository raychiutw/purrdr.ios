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
        NavigationStack {
            content
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                // 左上 X 等於「返回編輯」(#613);頁內兩顆大按鈕維持。
                .toolbar {
                    SheetCloseToolbar(identifier: "secretCheck.close") { check.returnToEditing() }
                }
        }
        .appSheet(detents: [.medium, .large])
        .presentationDragIndicator(.visible)
        // 容器自己一個 identifier,不蓋掉各列與按鈕的。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("secretCheck.sheet")
    }

    /// 偵測結果是系統清單的一個 section(分隔線、列高由系統給);頁內兩顆大按鈕在底部 `safeAreaBar`。
    private var content: some View {
        List {
            Section {
                ForEach(Array(review.findings.enumerated()), id: \.offset) { _, finding in
                    findingRow(finding)
                }
            } header: {
                Label {
                    Text("Message May Contain a Secret")
                        .accessibilityIdentifier("secretCheck.title")
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                .font(.headline)
                .textCase(nil)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Checked only on this device. Nothing was sent anywhere.")
            }
        }
        .appSheetList()
        .safeAreaBar(edge: .bottom) {
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
            .padding(.horizontal)
            .padding(.bottom)
        }
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
        case .gitLabToken: String(localized: "GitLab token")
        case .npmToken: String(localized: "npm token")
        case .huggingFaceToken: String(localized: "Hugging Face token")
        }
    }
}
