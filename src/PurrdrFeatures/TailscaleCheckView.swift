import SwiftUI

extension View {
    /// 主機要求 Tailscale SSH 重新驗證時，在畫面底部顯示驗證提示(開啟驗證頁、取消等待)。
    func tailscaleCheckPrompt(_ model: TailscaleCheckModel) -> some View {
        modifier(TailscaleCheckPromptModifier(model: model))
    }
}

private struct TailscaleCheckPromptModifier: ViewModifier {
    let model: TailscaleCheckModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if let url = model.url {
                    TailscaleCheckCard(url: url) { Task { await model.cancel() } }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.url)
    }
}

/// 驗證提示卡(內容層，不用 Liquid Glass)。連線中的具體描述 + 可取消(HIG Progress indicators)。
struct TailscaleCheckCard: View {
    let url: URL
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Sign In to Tailscale")
                    .font(.headline)
            } icon: {
                Image(systemName: "person.badge.key")
            }
            .accessibilityAddTraits(.isHeader)
            Text("This host asks you to sign in to Tailscale again. Purrdr continues on its own after you sign in.")
                .font(.subheadline)
                .foregroundStyle(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for sign-in…")
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
            .accessibilityElement(children: .combine)
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        // 容器自己是一個元素，裡面的按鈕保留各自的 identifier(否則容器的 identifier 會蓋掉它們)。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tailscaleCheck.prompt")
    }

    @ViewBuilder
    private var buttons: some View {
        Link(destination: url) {
            Label("Open Sign-In Page", systemImage: "safari")
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint("Opens the Tailscale sign-in page in your browser.")
        .accessibilityIdentifier("tailscaleCheck.open")
        Button("Cancel", role: .cancel, action: cancel)
            .frame(minHeight: 44)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("tailscaleCheck.cancel")
    }
}
