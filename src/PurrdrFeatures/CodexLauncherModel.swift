import Foundation
import Observation
import PurrdrCore

/// 設定頁「Codex 啟動器」的 model(行為規格 §4.2「Session 回報」,ADR-0002 的寫入例外)。【未實測】
///
/// 流程同 Claude 用量：打開 → 檢查主機(能不能安裝、以哪個使用者)→ 使用者確認才安裝並記住同意(每台主機個別)
/// → 關閉時移除，主機回到安裝前，成功才撤銷同意。
@MainActor
@Observable
public final class CodexLauncherModel {
    public enum State: Equatable {
        /// 還沒同意(或已移除)。
        case off
        /// 同意前檢查主機中。
        case checking
        /// 等使用者確認：會以 `user` 在主機上安裝。
        case confirming(user: String)
        case installing
        case on
        case removing
    }

    public private(set) var state: State = .off
    /// 上一次操作失敗的說明。
    public private(set) var message: String?

    private let host: CodexLauncherHost
    private let hostID: String
    private let consent: any HostWriteConsentStore
    private var feature: String { CodexLauncherHost.feature.id }

    /// - Parameter hostID: 同意以主機為單位記住。
    public init(host: CodexLauncherHost, hostID: String, consent: any HostWriteConsentStore) {
        self.host = host
        self.hostID = hostID
        self.consent = consent
        state = consent.isGranted(CodexLauncherHost.feature.id, host: hostID) ? .on : .off
    }

    /// 開關的值(開啟中、移除中都算開)。
    public var isOn: Bool {
        switch state {
        case .on, .installing, .removing: true
        case .off, .checking, .confirming: false
        }
    }

    /// 使用者打開：先檢查主機，再請使用者確認。
    public func request() async {
        guard state == .off else { return }
        message = nil
        state = .checking
        do {
            let inspection = try await host.inspect()
            state = .confirming(user: inspection.user)
        } catch {
            state = .off
            message = Self.describe(error)
        }
    }

    public func cancelConsent() {
        if case .confirming = state { state = .off }
    }

    /// 使用者確認：安裝(重新讀取，以最新狀態為準)並記住同意。
    public func confirm() async {
        guard case .confirming = state else { return }
        state = .installing
        do {
            try await host.install()
            consent.grant(feature, host: hostID)
            state = .on
        } catch {
            state = .off
            message = Self.describe(error)
        }
    }

    /// 關閉：移除啟動器，撤銷同意。移除失敗時維持開啟並說明。
    public func turnOff() async {
        guard state == .on else { return }
        message = nil
        state = .removing
        do {
            try await host.restore()
            consent.revoke(feature, host: hostID)
            state = .off
        } catch {
            state = .on
            message = Self.describe(error)
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case CodexLauncherError.codexAlreadyThere:
            String(localized: "~/.local/bin/codex already exists on this host, so Purrdr left it unchanged.")
        case HostFilesError.changedSinceRead:
            String(localized: "Files on the host changed while Purrdr was updating them. Nothing was changed; try again.")
        default:
            String(localized: "Couldn’t update the host: \(error.localizedDescription)")
        }
    }
}
