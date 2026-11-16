import SwiftUI

/// 第一次開啟的歡迎頁(#34;HIG Onboarding、檢核 20.14):一頁、可以直接關掉，說明要準備什麼，
/// 並讓人先用 Demo 主機體驗。不教系統操作、不放授權條款;設定頁可以再打開。
///
/// 只有一個 prominent 按鈕(「Try the Demo」);「Add Host」換成主機 sheet;「Rate Purrdr」開 App Store 撰寫評論頁(#37 故事 46)。
public struct WelcomeView: View {
    let tryDemo: () -> Void
    let addHost: () -> Void
    let rate: () -> Void
    let done: () -> Void

    public init(
        tryDemo: @escaping () -> Void, addHost: @escaping () -> Void, rate: @escaping () -> Void, done: @escaping () -> Void
    ) {
        self.tryDemo = tryDemo
        self.addHost = addHost
        self.rate = rate
        self.done = done
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Read, answer, and steer the coding agents that herdr runs on your host, and open a terminal into it, from your iPhone or iPad.")
                        .font(.body)
                        .accessibilityIdentifier("welcome.summary")
                }

                Section {
                    requirement(
                        "A Host Running herdr", systemImage: "desktopcomputer", id: "host",
                        detail: "A Mac, Linux, or Windows host with your agents running in herdr 0.9.5 or later.")
                    requirement(
                        "SSH Access", systemImage: "lock.shield", id: "ssh",
                        detail: "Tailscale SSH needs no keys or passwords. With OpenSSH, Purrdr makes a key on this iPhone or iPad for you to add to the host.")
                    requirement(
                        "Notifications Are Optional", systemImage: "bell.badge", id: "notifications",
                        detail: "With Purrdr Plus, a small host plugin tells you when an agent needs you. Chat and the terminal work without it.")
                } header: {
                    Text("What You Need")
                        .foregroundStyle(.secondaryText)
                }

                Section {
                    Button("Try the Demo", action: tryDemo)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("welcome.demo")
                    Button("Add Host", systemImage: "plus", action: addHost)
                        .accessibilityIdentifier("welcome.addHost")
                } footer: {
                    Text("The Demo host has sample conversations, so you can try every screen before you add a host.")
                        .foregroundStyle(.secondaryText)
                }

                Section {
                    Button("Rate Purrdr", systemImage: "star", action: rate)
                        .accessibilityIdentifier("welcome.rate")
                }
            }
            .accessibilityIdentifier("sheet.welcome")
            .navigationTitle("Welcome")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                        .accessibilityIdentifier("sheet.done")
                }
            }
        }
    }

    private func requirement(
        _ title: LocalizedStringKey, systemImage: String, id: String, detail: LocalizedStringKey
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
            }
        } icon: {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("welcome.requirement.\(id)")
    }
}
