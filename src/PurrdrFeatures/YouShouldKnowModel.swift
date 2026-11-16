import Foundation
import Observation
import PurrdrCore

/// 一台主機的「You should know」註記(#23,#37 故事 49–50,行為規格 F17)。每台主機各一份(`HostMember`)。
///
/// - 讀：約每 10 秒(列表與對話可見時)讀主機上 plugin 的 store;每 10 分鐘(或 store 不見時)重新找最新的 store。
///   讀取失敗不打擾使用者，保留上次的註記。
/// - 動作(深入了解、早就知道、略過;「在聊天中討論」= 把草稿放進輸入框 + 早就知道)會寫回主機上的 store,
///   這是 ADR-0002 的寫入例外：每台主機第一次動作前先說明以哪個使用者修改並徵得同意;可在設定撤掉 Purrdr 的修改。
@MainActor
@Observable
public final class YouShouldKnowModel {
    /// 等使用者同意的動作。
    public struct PendingConsent: Equatable {
        public var user: String
        public var action: YouShouldKnowAction
        public var note: YouShouldKnowNote
    }

    /// 顯示中的註記，新→舊。
    public private(set) var notes: [YouShouldKnowNote] = []
    public private(set) var pendingConsent: PendingConsent?
    public private(set) var message: String?
    /// 這台主機已同意寫回(設定頁提供「撤掉 Purrdr 的修改」)。
    public private(set) var isGranted: Bool
    public private(set) var isWorking = false

    static let pollInterval: Duration = .seconds(10)
    static let relocateInterval: TimeInterval = 10 * 60

    private let host: YouShouldKnowHost
    private let hostID: String
    private let consent: any HostWriteConsentStore
    private let sleep: @Sendable (Duration) async throws -> Void
    private var storePath: HostPath?
    private var locatedAt: Date?

    public init(host: YouShouldKnowHost, hostID: String, consent: any HostWriteConsentStore,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.host = host
        self.hostID = hostID
        self.consent = consent
        self.sleep = sleep
        isGranted = consent.isGranted(YouShouldKnowHost.featureID, host: hostID)
    }

    public func note(forSession id: String) -> YouShouldKnowNote? { notes.first { $0.sessionID == id } }

    /// 列表上「N 則註記」:只算列表裡有的聊天(以完整 session id 配對)。
    public func count(inSessions ids: Set<String>) -> Int { notes.filter { ids.contains($0.sessionID) }.count }

    /// 讀一次 store。
    public func refresh() async {
        do {
            if storePath == nil || locatedAt.map({ Date().timeIntervalSince($0) > Self.relocateInterval }) ?? true {
                storePath = try await host.locate()
                locatedAt = Date()
            }
            guard let path = storePath else { notes = []; return }
            if let store = try await host.read(path) {
                notes = store.notes
            } else {
                storePath = nil
                notes = []
            }
        } catch {
            // 註記只是提示：讀不到不打擾使用者，下次再讀。
        }
    }

    public func run() async {
        while !Task.isCancelled {
            await refresh()
            do { try await sleep(Self.pollInterval) } catch { return }
        }
    }

    /// 對註記做動作。這台主機還沒同意時先問(`pendingConsent`)。
    public func perform(_ action: YouShouldKnowAction, on note: YouShouldKnowNote) async {
        message = nil
        guard isGranted else {
            do {
                pendingConsent = PendingConsent(user: try await host.user(), action: action, note: note)
            } catch {
                message = Self.describe(error)
            }
            return
        }
        await write(action, on: note)
    }

    public func confirmConsent() async {
        guard let pending = pendingConsent else { return }
        pendingConsent = nil
        consent.grant(YouShouldKnowHost.featureID, host: hostID)
        isGranted = true
        await write(pending.action, on: pending.note)
    }

    public func cancelConsent() { pendingConsent = nil }

    /// 撤掉 Purrdr 對 store 的修改、撤銷同意。失敗時維持同意並說明。
    public func undoChanges() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await host.restore()
            consent.revoke(YouShouldKnowHost.featureID, host: hostID)
            isGranted = false
            message = nil
        } catch {
            message = Self.describe(error)
        }
        await refresh()
    }

    private func write(_ action: YouShouldKnowAction, on note: YouShouldKnowNote) async {
        isWorking = true
        defer { isWorking = false }
        do {
            guard let path = storePath else { throw YouShouldKnowError.storeNotFound }
            try await host.perform(action, on: note, at: path)
        } catch {
            message = Self.describe(error)
        }
        await refresh()
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case YouShouldKnowError.noteChanged:
            String(localized: "This note changed on the host. Showing the latest one.")
        case YouShouldKnowError.storeNotFound, YouShouldKnowError.invalidStore, HostWriteError.unusableFile, HostFilesError.tooLarge:
            String(localized: "Purrdr can’t safely update the notes file on this host.")
        case HostFilesError.changedSinceRead:
            String(localized: "Claude Code was updating the notes at the same time. Nothing was changed; try again.")
        default:
            String(localized: "Couldn’t update the host: \(error.localizedDescription)")
        }
    }
}
