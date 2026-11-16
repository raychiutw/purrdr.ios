#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 「You should know」的主機端(#23,ADR-0002):找 store、讀、經同意後寫回(compare-and-swap、保留未知內容),
/// 關閉時撤掉 Purrdr 的修改。在本機用真的 `/bin/sh` 跑，家目錄是暫存資料夾。
@Suite("You should know 註記(主機)")
struct YouShouldKnowHostTests {
    static let storePath = ".claude/plugins/store/cc-plugin-you-should-know_builtin-0123456789ab.json"
    static let sample = YouShouldKnowStoreTests.sample

    let host: LocalShellHost
    let ysk: YouShouldKnowHost

    init() throws {
        host = try LocalShellHost.temporary()
        ysk = YouShouldKnowHost(channel: host)
    }

    func setDate(_ seconds: TimeInterval, of path: String) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: host.url(path).path)
    }

    func storeObject() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: host.url(Self.storePath))) as? [String: Any])
    }

    @Test("找最新的 store;沒有 plugin store 時是 nil,其他 plugin 的 store 不算")
    func locatesNewestStore() async throws {
        _ = try host.write(Data("{}".utf8), to: ".claude/plugins/store/cc-plugin-agents-md_builtin-b0.json")
        #expect(try await ysk.locate() == nil)
        _ = try host.write(Data("{}".utf8), to: ".claude/plugins/store/cc-plugin-you-should-know_builtin-old.json")
        _ = try host.write(Data("{}".utf8), to: Self.storePath)
        try setDate(1_700_000_000, of: ".claude/plugins/store/cc-plugin-you-should-know_builtin-old.json")
        try setDate(1_700_000_100, of: Self.storePath)
        #expect(try await ysk.locate() == HostPath(Self.storePath))
    }

    @Test("沒有 ~/.claude:找不到 store,不是錯誤")
    func noClaudeFolder() async throws {
        #expect(try await ysk.locate() == nil)
    }

    @Test("讀 store 的註記")
    func readsNotes() async throws {
        _ = try host.write(Data(Self.sample.utf8), to: Self.storePath)
        let store = try #require(try await ysk.read(HostPath(Self.storePath)))
        #expect(store.notes.count == 2)
    }

    @Test("早就知道：寫回主機，保留未知內容")
    func knewItWritesBack() async throws {
        _ = try host.write(Data(Self.sample.utf8), to: Self.storePath)
        let path = HostPath(Self.storePath)
        let note = try #require(try await ysk.read(path)?.note(forSession: YouShouldKnowStoreTests.sessionA))
        try await ysk.perform(.knewIt, on: note, at: path)
        let object = try storeObject()
        #expect(object["known"] as? [String] == ["Tabs are not spaces", note.line])
        #expect(object["futureKey"] != nil)
        #expect(try await ysk.read(path)?.note(forSession: note.sessionID) == nil)
    }

    @Test("plugin 沒再改過：關閉後整個家目錄與第一次寫回前完全相同")
    func restoreExactlyWhenUnchanged() async throws {
        _ = try host.write(Data(Self.sample.utf8), to: Self.storePath)
        let before = try DirectorySnapshot(of: host.home)
        let path = HostPath(Self.storePath)
        let store = try #require(try await ysk.read(path))
        try await ysk.perform(.dismiss, on: try #require(store.note(forSession: YouShouldKnowStoreTests.sessionA)), at: path)
        let again = try #require(try await ysk.read(path))
        try await ysk.perform(.knewIt, on: try #require(again.note(forSession: YouShouldKnowStoreTests.sessionB)), at: path)
        #expect(try DirectorySnapshot(of: host.home) != before)

        try await ysk.restore()
        #expect(try DirectorySnapshot(of: host.home) == before)
    }

    @Test("plugin 之後又改過 store:關閉只撤掉 Purrdr 加進 known 的句子，plugin 的修改保留")
    func restoreMergesWhenPluginChangedStore() async throws {
        _ = try host.write(Data(Self.sample.utf8), to: Self.storePath)
        let path = HostPath(Self.storePath)
        let note = try #require(try await ysk.read(path)?.note(forSession: YouShouldKnowStoreTests.sessionB))
        try await ysk.perform(.knewIt, on: note, at: path)
        var object = try storeObject()
        object["known"] = (object["known"] as? [String] ?? []) + ["Plugin learned this"]
        object["typedPastInARow"] = 1
        _ = try host.write(try JSONSerialization.data(withJSONObject: object), to: Self.storePath)

        try await ysk.restore()
        let restored = try storeObject()
        #expect(restored["known"] as? [String] == ["Tabs are not spaces", "Plugin learned this"])
        #expect((restored["typedPastInARow"] as? NSNumber)?.intValue == 1)
        #expect(FileManager.default.fileExists(atPath: host.url(".purrdr").path) == false)
    }

    @Test("寫回時 plugin 剛好改了 store:重讀、重套、再試一次")
    func retriesOnceWhenStoreChanged() async throws {
        _ = try host.write(Data(Self.sample.utf8), to: Self.storePath)
        let racing = RacingHost(base: host, times: 1) {
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: host.url(Self.storePath))) as? [String: Any] ?? [:]
            object["seen"] = ["a", "b", "c"]
            _ = try host.write(try JSONSerialization.data(withJSONObject: object), to: Self.storePath)
        }
        let ysk = YouShouldKnowHost(channel: racing)
        let path = HostPath(Self.storePath)
        let note = try #require(try await ysk.read(path)?.note(forSession: YouShouldKnowStoreTests.sessionA))
        try await ysk.perform(.knewIt, on: note, at: path)
        let object = try storeObject()
        #expect(object["seen"] as? [String] == ["a", "b", "c"])
        #expect((object["known"] as? [String])?.last == note.line)
    }

    @Test("連續兩次都被 plugin 搶先：放棄並丟錯")
    func givesUpAfterSecondConflict() async throws {
        _ = try host.write(Data(Self.sample.utf8), to: Self.storePath)
        var counter = 0
        let racing = RacingHost(base: host, times: 2) {
            counter += 1
            _ = try host.write(Data((Self.sample + String(repeating: " ", count: counter)).utf8), to: Self.storePath)
        }
        let ysk = YouShouldKnowHost(channel: racing)
        let path = HostPath(Self.storePath)
        let note = try #require(try await ysk.read(path)?.note(forSession: YouShouldKnowStoreTests.sessionA))
        await #expect(throws: HostFilesError.changedSinceRead(path)) { try await ysk.perform(.knewIt, on: note, at: path) }
    }
}

/// 在前 `times` 次寫入指令送出前先改主機上的檔案(模擬 plugin 剛好同時寫入)。
final class RacingHost: HostChannel, @unchecked Sendable {
    let base: LocalShellHost
    private var remaining: Int
    private let interfere: () throws -> Void

    init(base: LocalShellHost, times: Int, interfere: @escaping () throws -> Void) {
        self.base = base
        remaining = times
        self.interfere = interfere
    }

    func execute(_ command: String) async throws -> any ExecSession {
        if remaining > 0, command.contains("check \"$@\"") {
            remaining -= 1
            try interfere()
        }
        return try await base.execute(command)
    }

    func openPTY(_ request: PTYRequest) async throws -> any PTYSession { try await base.openPTY(request) }
    func disconnect() async { await base.disconnect() }
}
#endif
