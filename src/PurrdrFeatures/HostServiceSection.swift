import PurrdrAgentFeatures
import PurrdrCore
import SwiftUI

/// 主機頁(ⓘ)的主機服務區塊(#290):版本、最新版本、立即更新、自動更新、上次結果;唯讀裝置停用並在註腳說明。
struct HostServiceSection: View {
    let model: HostServiceStatusModel

    var body: some View {
        Section {
            switch model.content {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("hostStatus.hostService.loading")
            case .loaded(let status):
                loaded(status)
            case .needsNewerHostService(let installedVersion):
                Text(needsNewerText(installedVersion))
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("hostStatus.hostService.needsUpdate")
            case .notInstalledCopy:
                Text("This host service isn’t the installed copy, so it can’t be managed from Purrdr.")
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("hostStatus.hostService.notInstalled")
            case .failed(let message):
                ErrorLabel(message)
                    .accessibilityIdentifier("hostStatus.hostService.error")
                Button("Try Again") { Task { await model.refresh() } }
                    .accessibilityIdentifier("hostStatus.hostService.retry")
            }
        } header: {
            Text("Host Service")
                .foregroundStyle(.secondaryText)
        } footer: {
            if model.isReadOnly, case .loaded = model.content {
                Text("This device is paired read-only, so it can’t update the host service or change automatic updates.")
                    .foregroundStyle(.secondaryText)
                    .accessibilityIdentifier("hostStatus.hostService.readOnly")
            }
        }
        .task { await model.refresh() }
    }

    @ViewBuilder
    private func loaded(_ status: HostServiceUpdateStatus) -> some View {
        LabeledContent("Version") { Text(verbatim: status.installedVersion) }
            .accessibilityIdentifier("hostStatus.hostService.version")
        LabeledContent("Latest Version") {
            if let latest = status.latestVersion {
                Text(verbatim: latest)
            } else {
                Text("Couldn’t Check")
            }
        }
        .accessibilityIdentifier("hostStatus.hostService.latest")
        if status.updateAvailable || model.update != .idle {
            updateRow(status)
        }
        Toggle("Automatic Updates", isOn: Binding(get: { status.autoUpdate }, set: { enabled in Task { await model.setAutoUpdate(enabled) } }))
            .disabled(!model.canChangeSettings)
            .accessibilityIdentifier("hostStatus.hostService.autoUpdate")
        if let error = model.autoUpdateError {
            ErrorLabel(error)
                .font(.footnote)
                .accessibilityIdentifier("hostStatus.hostService.autoUpdateError")
        }
        if let last = status.lastUpdate {
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Last Update") {
                    if let date = last.checkedAt {
                        Text(date, format: .dateTime.month().day().hour().minute())
                    } else {
                        Text(verbatim: last.checkedAtText)
                    }
                }
                Text(verbatim: last.result)
                    .font(.footnote)
                    .foregroundStyle(.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("hostStatus.hostService.lastUpdate")
        }
    }

    @ViewBuilder
    private func updateRow(_ status: HostServiceUpdateStatus) -> some View {
        switch model.update {
        case .idle:
            Button {
                Task { await model.updateNow() }
            } label: {
                Label("Update to \(status.latestVersion ?? "")", systemImage: "arrow.down.circle")
            }
            .disabled(!model.canUpdate)
            .accessibilityIdentifier("hostStatus.hostService.update")
        case .starting:
            progress(Text("Starting the update…"))
        case .waitingForRestart(let version):
            progress(Text("Updating to \(version). The host service restarts, then Purrdr reconnects…"))
        case .succeeded(let version):
            outcome(Text("Updated to \(version)."), symbol: "checkmark.circle.fill", tint: .tint)
        case .rolledBack(let version, let runningVersion):
            outcome(
                Text("\(version) didn’t start, so the host put \(runningVersion) back."), symbol: "arrow.uturn.backward.circle.fill",
                tint: .orange)
        case .upToDate(let version):
            outcome(Text("Already up to date (\(version))."), symbol: "checkmark.circle.fill", tint: .tint)
        case .unconfirmed(let version):
            outcome(
                Text("Couldn’t confirm the update to \(version). Pull to refresh to check again."), symbol: "questionmark.circle.fill",
                tint: .orange)
        case .failed(let message):
            ErrorLabel(message)
                .accessibilityIdentifier("hostStatus.hostService.updateResult")
        }
    }

    private func progress(_ text: Text) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            text
                .foregroundStyle(.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hostStatus.hostService.updating")
    }

    /// 顏色只上在符號，文字用主要色(DESIGN.md 狀態色)。
    private func outcome(_ text: Text, symbol: String, tint: some ShapeStyle) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .accessibilityIdentifier("hostStatus.hostService.updateResult")
    }

    private func needsNewerText(_ installedVersion: String?) -> String {
        let required = HostServiceFeature.hostServiceManagement.minimumVersion.description
        if let installedVersion {
            return String(localized: "Managing the host service from Purrdr needs host service \(required) or later (this host has \(installedVersion)). Update it on the host.")
        }
        return String(localized: "Managing the host service from Purrdr needs host service \(required) or later. Update it on the host.")
    }
}
