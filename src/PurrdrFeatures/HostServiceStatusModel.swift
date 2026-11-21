import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore

/// 主機頁(ⓘ)的主機服務區塊(#290):版本、有沒有新版、自動更新與上次結果;立即更新後等重新連線，
/// 以 `welcome` 的版本判斷成功或已退回。
@MainActor
@Observable
public final class HostServiceStatusModel {
    /// 區塊的內容。
    public enum Content: Equatable, Sendable {
        case loading
        case loaded(HostServiceUpdateStatus)
        /// 主機服務太舊，還不能從 app 管理(`installedVersion` 是 `welcome` 回報的版本)。
        case needsNewerHostService(installedVersion: String?)
        /// 跑的不是安裝好的主機服務。
        case notInstalledCopy
        /// 讀不到(說明文字)。
        case failed(String)
    }

    /// 立即更新的進度與結果。
    public enum UpdatePhase: Equatable, Sendable {
        case idle
        /// 送出更新請求中。
        case starting
        /// 主機服務正在更新並重啟，等它重新連線。
        case waitingForRestart(to: String)
        case succeeded(version: String)
        /// 新版起不來，主機已換回 `runningVersion`。
        case rolledBack(version: String, runningVersion: String)
        case upToDate(version: String)
        /// 時間內沒等到新版本，也沒看到退回。
        case unconfirmed(to: String)
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .starting, .waitingForRestart: true
            default: false
            }
        }
    }

    public private(set) var content: Content = .loading
    public private(set) var update: UpdatePhase = .idle
    /// 唯讀裝置不能更新、不能改自動更新。
    public private(set) var isReadOnly = false
    public private(set) var isChangingAutoUpdate = false
    /// 改自動更新失敗的說明。
    public private(set) var autoUpdateError: String?

    private let connection: any HostConnection & HostServiceManaging
    private let sleep: Sleep
    private let restartPollInterval: Duration
    private let restartLimit: Duration

    /// - Parameters:
    ///   - restartPollInterval: 立即更新後多久試一次重新連線。
    ///   - restartLimit: 最多等多久(下載、核對、重啟與退回都在這段時間內)。
    public init(
        connection: any HostConnection & HostServiceManaging, sleep: @escaping Sleep = Sleeping.task,
        restartPollInterval: Duration = .seconds(3), restartLimit: Duration = .seconds(180)
    ) {
        self.connection = connection
        self.sleep = sleep
        self.restartPollInterval = restartPollInterval
        self.restartLimit = restartLimit
    }

    public var canChangeSettings: Bool {
        guard case .loaded = content else { return false }
        return !isReadOnly && !update.isBusy && !isChangingAutoUpdate
    }

    public var canUpdate: Bool {
        guard canChangeSettings, case .loaded(let status) = content else { return false }
        return status.updateAvailable
    }

    /// 讀狀態(畫面出現、下拉重新整理)。
    public func refresh() async {
        isReadOnly = (try? await connection.isReadOnlyDevice()) ?? false
        do {
            content = .loaded(try await connection.hostServiceUpdateStatus())
        } catch {
            content = Self.content(for: error)
        }
        // 無法確認的更新：重讀時主機已是新版就算成功。
        if case .unconfirmed(let target) = update, case .loaded(let status) = content, status.installedVersion == target {
            update = .succeeded(version: target)
        }
    }

    /// 立即更新：等主機服務重啟後重新連線，以 `welcome` 的版本確認;版本沒變且狀態出現這次的退回就是已退回。
    public func updateNow() async {
        guard canUpdate, case .loaded(let before) = content else { return }
        update = .starting
        let target: String
        do {
            switch try await connection.updateHostService() {
            case .upToDate(let version):
                update = .upToDate(version: version)
                await refresh()
                return
            case .started(_, let to):
                target = to
            }
        } catch {
            update = .failed(Self.updateMessage(for: error))
            return
        }
        update = .waitingForRestart(to: target)
        update = await waitForRestart(to: target, previousAttempt: before.lastUpdate)
        await refresh()
    }

    /// 開關自動更新;畫面顯示主機回報的值。
    public func setAutoUpdate(_ enabled: Bool) async {
        guard canChangeSettings, case .loaded(var status) = content, status.autoUpdate != enabled else { return }
        isChangingAutoUpdate = true
        autoUpdateError = nil
        defer { isChangingAutoUpdate = false }
        do {
            status.autoUpdate = try await connection.setHostServiceAutoUpdate(enabled)
            content = .loaded(status)
        } catch {
            autoUpdateError = Self.updateMessage(for: error)
        }
    }

    private func waitForRestart(to target: String, previousAttempt: HostServiceLastUpdate?) async -> UpdatePhase {
        var waited = Duration.zero
        while waited < restartLimit {
            do {
                try await sleep(restartPollInterval)
            } catch {
                return .unconfirmed(to: target)
            }
            waited += restartPollInterval
            guard let version = try? await connection.reconnectForHostServiceVersion() else { continue }
            if version == target { return .succeeded(version: target) }
            // 重啟前的舊連線也回舊版本：要看到這次更新留下的退回紀錄才算退回。
            if let status = try? await connection.hostServiceUpdateStatus(), status.rolledBack == target,
                status.lastUpdate != previousAttempt
            {
                return .rolledBack(version: target, runningVersion: version)
            }
        }
        return .unconfirmed(to: target)
    }

    private static func content(for error: any Error) -> Content {
        switch error {
        case HostServiceError.hostServiceUpdateRequired(_, let installedVersion):
            .needsNewerHostService(installedVersion: installedVersion)
        case HostServiceManagementError.notInstalledCopy:
            .notInstalledCopy
        default:
            .failed(HostErrorText.message(for: error))
        }
    }

    private static func updateMessage(for error: any Error) -> String {
        switch error {
        case HostServiceManagementError.updateInProgress:
            String(localized: "An update of the host service is already in progress.")
        case HostServiceManagementError.updateFailed:
            String(localized: "The host couldn’t start the update. Make sure it’s online, then try again.")
        case HostServiceManagementError.notInstalledCopy:
            String(localized: "This host service isn’t the installed copy, so it can’t be managed from Purrdr.")
        default:
            HostErrorText.message(for: error)
        }
    }
}
