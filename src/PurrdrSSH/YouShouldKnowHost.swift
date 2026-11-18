import Foundation
import PurrdrCore

/// 「You should know」註記的主機端(#23,行為規格 F17;寫回是 ADR-0002 的寫入例外)。
///
/// - 找 store:`~/.claude/plugins/store/cc-plugin-you-should-know_<marketplace>-<hash>.json` 裡最新的可讀檔。
///   (`CLAUDE_CONFIG_DIR` 只存在使用者的互動 shell,SSH exec 看不到，所以固定看 `~/.claude`。)
/// - 寫回：經 `ReversibleHostWrite` compare-and-swap(讀取後 plugin 改過就整批不寫);衝突時重讀、重套、再試一次，
///   第二次放棄。安裝紀錄記下第一次寫回前的內容;Purrdr 加進 `known` 的句子另記在 `~/.purrdr/you-should-know/added-known.json`。
/// - 還原：plugin 沒再改過 → 換回第一次寫回前的位元組;改過 → 只把 Purrdr 加進 `known` 的句子拿掉，其餘保留。
///
/// 是否徵得同意由畫面 model 負責(`HostWriteConsentStore`)。
public struct YouShouldKnowHost: YouShouldKnowHosting {
    public static let featureID = YouShouldKnowFeature.id
    public static let storeDirectory: HostPath = ".claude/plugins/store"
    static let storePrefix = "cc-plugin-you-should-know_"
    static let storeSuffix = ".json"
    static let addedKnownPath = HostWriteFeature(id: featureID, userFiles: []).ownFile("added-known.json")

    let channel: any HostChannel
    let files: HostFiles
    let now: @Sendable () -> Date

    /// - Parameter files: 讀 store 用的主機檔案(每台主機共用長駐讀取的那份);`nil` 時每次讀是一次性指令。
    public init(channel: any HostChannel, files: HostFiles? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.channel = channel
        self.files = files ?? HostFiles(channel: channel)
        self.now = now
    }

    static func feature(_ store: [HostPath]) -> HostWriteFeature { HostWriteFeature(id: featureID, userFiles: store) }

    /// 最新的 store;plugin 沒開過(或沒有 `~/.claude`)時是 `nil`。
    public func locate() async throws -> HostPath? {
        try await files.newest(in: Self.storeDirectory, prefix: Self.storePrefix, suffix: Self.storeSuffix)
    }

    /// 條件式讀 store(沒有已知版本時一定讀):與 `known` 版本相同時是 `.unchanged`;檔案不見時是 `.changed(nil, …)`;
    /// 不是 JSON 物件丟 `YouShouldKnowError.invalidStore`。
    public func read(_ path: HostPath, ifChangedFrom known: HostFileVersion?) async throws -> HostFileUpdate<YouShouldKnowStore?> {
        let read = try await files.read([path], knownVersions: known.map { [path: $0] } ?? [:])
        if read.unchanged.contains(path) { return .unchanged }
        switch read[path] ?? .missing {
        case .missing, .missingDirectory:
            return .changed(nil, version: nil)
        case .file(let data, let version):
            guard let store = YouShouldKnowStore(data: data) else { throw YouShouldKnowError.invalidStore }
            return .changed(store, version: version)
        case .notRegularFile, .unreadable, .tooLarge:
            throw HostWriteError.unusableFile(path)
        }
    }

    /// 同意畫面要說明「以哪個使用者」修改。
    public func user() async throws -> String {
        try await files.read([Self.addedKnownPath]).user
    }

    /// 對註記做動作並寫回主機。plugin 剛好同時寫入時重試一次。
    public func perform(_ action: YouShouldKnowAction, on note: YouShouldKnowNote, at path: HostPath) async throws {
        do {
            try await performOnce(action, on: note, at: path)
        } catch HostFilesError.changedSinceRead {
            try await performOnce(action, on: note, at: path)
        }
    }

    private func performOnce(_ action: YouShouldKnowAction, on note: YouShouldKnowNote, at path: HostPath) async throws {
        let write = ReversibleHostWrite(channel: channel, feature: Self.feature([path]))
        let now = now()
        try await write.install(also: [Self.addedKnownPath]) { inspection in
            guard case .file(let data, _)? = inspection.read[path] else { throw YouShouldKnowError.storeNotFound }
            guard let store = YouShouldKnowStore(data: data) else { throw YouShouldKnowError.invalidStore }
            let updated = try store.applying(action, to: note, now: now)
            var added = inspection.read[Self.addedKnownPath]?.contents.flatMap(Self.decodeAdded) ?? []
            let before = Set(Self.known(in: data).map { $0.lowercased() })
            if action == .knewIt, !before.contains(note.line.lowercased()) { added.append(note.line) }
            return HostWritePlan(userFiles: [path: updated], ownFiles: ["added-known.json": .init(try JSONEncoder().encode(added))])
        }
    }

    /// 撤掉 Purrdr 的修改，移除 `~/.purrdr/you-should-know/`。沒寫回過時什麼都不做。
    public func restore() async throws {
        let journalOnly = ReversibleHostWrite(channel: channel, feature: Self.feature([]))
        let inspection = try await journalOnly.inspect(also: [Self.addedKnownPath])
        guard let journal = inspection.journal else { return }
        let added = Set((inspection.read[Self.addedKnownPath]?.contents.flatMap(Self.decodeAdded) ?? []).map { $0.lowercased() })
        let write = ReversibleHostWrite(channel: channel, feature: Self.feature(journal.entries.map { HostPath($0.path) }))
        try await write.restore { _, current, _ in
            guard var root = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any] else { return current }
            guard let known = root["known"] as? [Any] else { return current }
            let kept = known.filter { !(($0 as? String).map { added.contains($0.lowercased()) } ?? false) }
            guard kept.count != known.count else { return current }
            root["known"] = kept
            return try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
        }
    }

    static func decodeAdded(_ data: Data) -> [String]? { try? JSONDecoder().decode([String].self, from: data) }

    static func known(in data: Data) -> [String] {
        (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["known"] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
