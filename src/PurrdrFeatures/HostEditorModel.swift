import Foundation
import Observation
import PurrdrCore

/// 主機的儲存。正式實作是 `KeychainHostStore`(主機設定與 pin 存 Keychain,僅本裝置、解鎖後)。
@MainActor
public protocol HostStore: AnyObject {
    func loadHosts() throws -> [HostConfiguration]
    func save(_ host: HostConfiguration) throws
    func delete(_ id: UUID) throws
}

/// 新增／編輯主機畫面的 model(行為規格 F1.2、§8.2)。
///
/// 儲存前必須通過一次連線測試;測試後改了任何欄位都要重測。第一次連線先讓使用者確認 host key 指紋，
/// 確認後才登入;指紋改變時阻擋。測試用暫時連線，測完即拆。
@MainActor
@Observable
public final class HostEditorModel {
    public enum Phase: Equatable {
        case editing
        case testing
        /// 第一次連到這台主機:請使用者確認指紋(TOFU)。
        case confirmHostKey(HostKeyFingerprint)
        /// 主機出示的 key 與已存的不同。
        case hostKeyChanged(presented: HostKeyFingerprint, pinned: HostKeyFingerprint)
        /// 主機的 herdr 低於 0.9.5,可在確認後更新。
        case needsUpdate(HerdrVersion)
        case updating
        case tested(HostProbeReport)
        case failed(String)
    }

    public var name = ""
    public var address = ""
    public var port = "22"
    public var username = ""
    /// 空白為 `herdr`。
    public var herdrPath = ""
    /// 空白為預設 session。
    public var herdrSession = ""
    public private(set) var phase: Phase = .editing

    /// 是否是編輯既有主機。
    public var isEditing: Bool { existing != nil }

    private let store: any HostStore
    private let existing: HostConfiguration?
    private let makeChannel: @MainActor (SSHEndpoint, HostKeyFingerprint?) -> any HostChannel
    /// 這次編輯中使用者確認過的指紋，以及它屬於哪個端點。
    private var accepted: (fingerprint: HostKeyFingerprint, endpoint: SSHEndpoint)?
    private var tested: (draft: Draft, report: HostProbeReport)?
    private var attempt = 0

    public init(
        store: any HostStore, editing: HostConfiguration? = nil,
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?) -> any HostChannel
    ) {
        self.store = store
        existing = editing
        self.makeChannel = makeChannel
        if let editing {
            name = editing.name
            address = editing.endpoint.host
            port = String(editing.endpoint.port)
            username = editing.endpoint.username
            herdrPath = editing.herdr.path == "herdr" ? "" : editing.herdr.path
            herdrSession = editing.herdr.session ?? ""
        }
    }

    /// 從主機分享連結匯入：新主機，欄位帶入分享內容。分享內容附的 host key 指紋視為已確認，
    /// 所以連線測試只接受那一把 key(主機出示別的 key 時一樣阻擋);仍要測試通過才能儲存。
    public convenience init(
        store: any HostStore, importing shared: SharedHost,
        makeChannel: @escaping @MainActor (SSHEndpoint, HostKeyFingerprint?) -> any HostChannel
    ) {
        self.init(store: store, editing: nil, makeChannel: makeChannel)
        name = shared.name
        address = shared.endpoint.host
        port = String(shared.endpoint.port)
        username = shared.endpoint.username
        herdrPath = shared.herdr.path == "herdr" ? "" : shared.herdr.path
        herdrSession = shared.herdr.session ?? ""
        if let pin = shared.hostKeyPin { accepted = (pin, shared.endpoint) }
    }

    // MARK: - 狀態

    public var canTest: Bool { draft != nil && phase != .testing && phase != .updating }

    /// 最近一次測試成功，而且之後沒有改過任何欄位。
    public var canSave: Bool {
        guard let tested, case .tested = phase else { return false }
        return tested.draft == draft
    }

    /// 有沒有未儲存的變更(按取消時要確認放棄)。
    public var hasChanges: Bool {
        guard let existing else { return !(name.isEmpty && address.isEmpty && username.isEmpty && herdrPath.isEmpty && herdrSession.isEmpty) }
        return draft?.endpoint != existing.endpoint || draft?.name != existing.name || draft?.herdr != existing.herdr
    }

    /// 目前信任的指紋(已存或剛確認)。顯示用。
    public var hostKeyFingerprint: HostKeyFingerprint? { draft.flatMap(pin(for:)) }

    // MARK: - 動作

    /// 連線測試：主機 OS、herdr 版本、snapshot、agent 整合。
    public func test() async {
        guard let draft else { return }
        attempt += 1
        let current = attempt
        phase = .testing
        let pin = pin(for: draft)
        let channel = makeChannel(draft.endpoint, pin)
        let result: Result<HostProbeReport, any Error>
        do {
            result = .success(try await HostProbe(channel: channel, herdr: draft.herdr).run())
        } catch {
            result = .failure(error)
        }
        await channel.disconnect()
        // 測試期間使用者取消或又按了一次：舊的結果不算。
        guard current == attempt else { return }
        switch result {
        case .success(let report):
            tested = (Draft(draft, pin: pin), report)
            phase = .tested(report)
        case .failure(SSHConnectionError.hostKeyUnverified(let presented)):
            phase = .confirmHostKey(presented)
        case .failure(SSHConnectionError.hostKeyChanged(let presented, let pinned)):
            phase = .hostKeyChanged(presented: presented, pinned: pinned)
        case .failure(HostProbeError.herdrOutdated(let version)):
            phase = .needsUpdate(version)
        case .failure(let error):
            phase = .failed(HostErrorText.message(for: error))
        }
    }

    /// 取消進行中的測試。
    public func cancelTest() {
        attempt += 1
        phase = .editing
    }

    /// 信任主機剛剛出示的那一把 key,再重新測試。永遠不清空 pin 然後信任下一個回應者(行為規格 §8.2)。
    public func trustPresentedHostKey() async {
        guard let draft else { return }
        let presented: HostKeyFingerprint
        switch phase {
        case .confirmHostKey(let fingerprint), .hostKeyChanged(let fingerprint, _): presented = fingerprint
        default: return
        }
        accepted = (presented, draft.endpoint)
        await test()
    }

    /// 不信任、不更新：回到編輯。
    public func dismissPrompt() {
        phase = .editing
    }

    /// 使用者確認後在主機上執行 `herdr update --handoff`,再重新測試。
    public func updateHerdr() async {
        guard let draft, case .needsUpdate = phase else { return }
        phase = .updating
        let channel = makeChannel(draft.endpoint, pin(for: draft))
        do {
            try await HostProbe(channel: channel, herdr: draft.herdr).updateHerdr()
            await channel.disconnect()
        } catch {
            await channel.disconnect()
            phase = .failed(HostErrorText.message(for: error))
            return
        }
        await test()
    }

    /// 儲存。測試沒通過或之後改過欄位就不存;寫入失敗時留在編輯器並說明原因。
    @discardableResult
    public func save() -> HostConfiguration? {
        guard canSave, let tested else { return nil }
        let host = HostConfiguration(
            id: existing?.id ?? UUID(), name: tested.draft.name, endpoint: tested.draft.endpoint,
            herdr: tested.draft.herdr, operatingSystem: tested.report.operatingSystem, hostKeyPin: tested.draft.pin)
        do {
            try store.save(host)
            return host
        } catch {
            phase = .failed("Couldn’t save this host on this device. \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 內部

    private struct Draft: Equatable {
        var name: String
        var endpoint: SSHEndpoint
        var herdr: HerdrInstallation
        var pin: HostKeyFingerprint?

        init(_ draft: Draft, pin: HostKeyFingerprint?) {
            self = draft
            self.pin = pin
        }

        init(name: String, endpoint: SSHEndpoint, herdr: HerdrInstallation) {
            self.name = name
            self.endpoint = endpoint
            self.herdr = herdr
        }
    }

    private var draft: Draft? {
        let name = name.trimmingCharacters(in: .whitespaces)
        let address = address.trimmingCharacters(in: .whitespaces)
        let username = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !address.isEmpty, !username.isEmpty,
              let port = Int(port.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(port) else { return nil }
        let base = Draft(
            name: name, endpoint: SSHEndpoint(host: address, port: port, username: username),
            herdr: HerdrInstallation(path: herdrPath, session: herdrSession))
        return Draft(base, pin: pin(for: base))
    }

    /// 只有主機或埠改變(或新主機)才重設 pin;改名稱、使用者、herdr 設定不重設(行為規格 §8.2)。
    private func pin(for draft: Draft) -> HostKeyFingerprint? {
        if let accepted, Self.sameMachine(accepted.endpoint, draft.endpoint) { return accepted.fingerprint }
        if let existing, Self.sameMachine(existing.endpoint, draft.endpoint) { return existing.hostKeyPin }
        return nil
    }

    private static func sameMachine(_ lhs: SSHEndpoint, _ rhs: SSHEndpoint) -> Bool {
        lhs.host == rhs.host && lhs.port == rhs.port
    }
}
