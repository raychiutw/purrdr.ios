import Foundation
import Observation
import PurrdrAgentFeatures
import PurrdrCore
import PurrdrSSH

/// 一台主機的主機主題(#23;選取中主機的才套用到畫面):經同意後套用主機 herdr 的配色到對話與終端機。
///
/// - 同意流程與 Claude 用量相同(ADR-0002):檢查主機 → 說明以哪個使用者寫入參考檔 → 確認才寫入並記住同意。
/// - 開著時隨列表約每 10 秒讀一次主機的 `config.toml`(行為規格 F16 的頻率);讀取失敗保留目前的主題、不打擾使用者。
/// - 關閉：移除參考檔、撤銷同意，回到 App 自己的配色(主機上的 herdr 設定從不修改)。
@MainActor
@Observable
public final class HostThemeModel {
    public enum State: Equatable {
        case off
        case checking
        case confirming(user: String)
        case installing
        case on
        case turningOff
    }

    public private(set) var state: State = .off
    /// 套用中的主題;`nil` = App 自己的配色。
    public private(set) var theme: HostTheme?
    public private(set) var message: String?

    static let pollInterval: Duration = .seconds(10)

    /// 定期讀取：每個套用主題的視窗都 `attach()`,只跑一份。
    @ObservationIgnored public private(set) lazy var liveUpdates = SharedRun { [weak self] in await self?.run() }
    /// 上次讀到的 `config.toml` 版本(下次讀取沒變就不傳內容)。
    @ObservationIgnored private var configVersion: HostFileVersion?

    private let host: HostThemeHost
    private let hostID: String
    private let consent: any HostWriteConsentStore
    private let sleep: Sleep
    private var feature: String { HostThemeHost.feature.id }

    public init(host: HostThemeHost, hostID: String, consent: any HostWriteConsentStore,
                sleep: @escaping Sleep = Sleeping.task) {
        self.host = host
        self.hostID = hostID
        self.consent = consent
        self.sleep = sleep
        state = consent.isGranted(HostThemeHost.feature.id, host: hostID) ? .on : .off
    }

    /// 使用者打開「使用主機主題」:先檢查主機，再請使用者確認。
    public func requestTheme() async {
        guard state == .off else { return }
        message = nil
        state = .checking
        do {
            state = .confirming(user: try await host.inspect().user)
        } catch {
            state = .off
            message = Self.describe(error)
        }
    }

    public func cancelConsent() {
        if case .confirming = state { state = .off }
    }

    public func confirm() async {
        guard case .confirming = state else { return }
        state = .installing
        do {
            try await host.install()
            consent.grant(feature, host: hostID)
            state = .on
            await refresh()
        } catch {
            state = .off
            message = Self.describe(error)
        }
    }

    /// 關閉：移除參考檔、撤銷同意。移除失敗時維持開啟並說明。
    public func turnOff() async {
        guard state == .on else { return }
        state = .turningOff
        do {
            try await host.restore()
            consent.revoke(feature, host: hostID)
            theme = nil
            configVersion = nil
            message = nil
            state = .off
        } catch {
            state = .on
            message = Self.describe(error)
        }
    }

    /// 讀一次主機的主題(只在已同意時)。讀取失敗保留目前的主題(行為規格 F16)。
    public func refresh() async {
        guard state == .on else { return }
        guard case .changed(let theme, let version)? = try? await host.readTheme(ifChangedFrom: configVersion) else { return }
        self.theme = theme
        configVersion = version
    }

    /// 已同意時約每 10 秒讀一次，直到所在的 task 被取消。
    public func run() async {
        while !Task.isCancelled {
            await refresh()
            do { try await sleep(Self.pollInterval) } catch { return }
        }
    }

    static func describe(_ error: any Error) -> String {
        String(localized: "Couldn’t update the host: \(error.localizedDescription)")
    }
}
