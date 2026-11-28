import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 真主機整合測試的共用小工具(#694)。真主機測試本身預設略過,這裡驗證它們依賴的邏輯。
@Suite("真主機整合測試的清理與守門")
struct RealHostTestSupportTests {
    @Test("暫存資料夾名稱是 purrdr-test- 加 8 碼亂數,兩次不同")
    func scratchNames() {
        let a = RealHostScratch.makeName()
        let b = RealHostScratch.makeName()
        #expect(a != b)
        #expect(RealHostScratch.isTestFolderName(a))
        #expect(!RealHostScratch.isTestFolderName("purrdr-test-"))
        #expect(!RealHostScratch.isTestFolderName("purrdr-test-../x"))
    }

    @Test("刪除指令只接受暫存位置底下的 purrdr-test 資料夾,其他一律拒絕")
    func removeCommandGuards() {
        #expect(RealHostScratch.removeCommand(path: "/tmp/purrdr-test-0a1b2c3d") != nil)
        #expect(RealHostScratch.removeCommand(path: "/var/folders/x/T/purrdr-test-0a1b2c3d") != nil)
        #expect(RealHostScratch.removeCommand(path: "/home/me") == nil)
        #expect(RealHostScratch.removeCommand(path: "/") == nil)
        #expect(RealHostScratch.removeCommand(path: "") == nil)
        #expect(RealHostScratch.removeCommand(path: "/tmp/purrdr-test-0a1b2c3d/../..") == nil)
        #expect(RealHostScratch.removeCommand(path: "/tmp/purrdr-test-0a1b2c3d; rm -rf ~") == nil)
        #expect(RealHostScratch.removeCommand(path: "~/purrdr-test-0a1b2c3d") == nil)
    }

    @Test("真的 /bin/sh:建立在暫存位置、不碰家目錄;刪除後不在;家目錄不變")
    func createAndRemoveOnShell() async throws {
        let host = try LocalShellHost.temporary()
        let before = try DirectorySnapshot(of: host.home)
        let session = try await host.execute(RealHostScratch.createCommand(name: "purrdr-test-0a1b2c3d"))
        await session.closeStdin()
        let path = try await session.collectOutput().stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(path.hasSuffix("/purrdr-test-0a1b2c3d"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!path.hasPrefix(host.home.path(percentEncoded: false) + "/"), "不能寫進家目錄")
        #expect(path.hasPrefix(host.temporaryDirectory.path(percentEncoded: false)), "要寫在 TMPDIR")
        defer { try? FileManager.default.removeItem(at: host.temporaryDirectory) }
        #expect(try DirectorySnapshot(of: host.home) == before)

        let remove = try #require(RealHostScratch.removeCommand(path: path))
        let removal = try await host.execute(remove)
        await removal.closeStdin()
        _ = try await removal.collectOutput()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("清理在主體丟錯時仍照後進先出執行,並把原本的錯誤丟出去")
    func cleanupRunsOnFailure() async {
        struct Boom: Error {}
        let order = Recorder()
        do {
            try await RealHostCleanup.run { cleanup in
                await cleanup.add { await order.append("第一個") }
                await cleanup.add { await order.append("第二個") }
                throw Boom()
            }
            Issue.record("應該丟錯")
        } catch is Boom {
        } catch { Issue.record("錯誤不對:\(error)") }
        #expect(await order.items == ["第二個", "第一個"])
    }

    @Test("清理在成功時也執行,回傳主體結果")
    func cleanupRunsOnSuccess() async throws {
        let order = Recorder()
        let value = try await RealHostCleanup.run { cleanup in
            await cleanup.add { await order.append("done") }
            return 7
        }
        #expect(value == 7)
        #expect(await order.items == ["done"])
    }

    @Test("主體被取消時清理照跑")
    func cleanupRunsOnCancellation() async {
        let order = Recorder()
        let task = Task {
            try await RealHostCleanup.run { cleanup in
                await cleanup.add { await order.append("cleaned") }
                try await Task.sleep(for: .seconds(60))
            }
        }
        await Task.yield()
        task.cancel()
        _ = try? await task.value
        #expect(await order.items == ["cleaned"])
    }

    @Test("指紋必填:沒設或空白就略過,有設就解析")
    func fingerprintRequired() {
        #expect(RealHostGate.fingerprint(from: [:]) == nil)
        #expect(RealHostGate.fingerprint(from: ["PURRDR_REAL_HOST_FINGERPRINT": "  "]) == nil)
        #expect(RealHostGate.fingerprint(from: ["PURRDR_REAL_HOST_FINGERPRINT": "SHA256:abc"]) != nil)
        #expect(!RealHostGate.sshEnabled(from: ["PURRDR_REAL_HOST": "u@h"]))
        #expect(RealHostGate.sshEnabled(from: ["PURRDR_REAL_HOST": "u@h", "PURRDR_REAL_HOST_FINGERPRINT": "SHA256:abc"]))
        #expect(!RealHostGate.sshEnabled(from: ["PURRDR_REAL_HOST_FINGERPRINT": "SHA256:abc"]))
    }

    @Test("配對碼換到的權杖在主體結束時撤銷,失敗也撤銷;既有權杖不撤銷")
    func pairedTokenRevoked() async throws {
        struct Boom: Error {}
        let revoked = Recorder()
        do {
            _ = try await RealHostToken.with(
                environment: ["PURRDR_HTTPS_PAIRING_CODE": "K7QM-2XPA"],
                pair: { "tok-1" }, revoke: { await revoked.append($0) }) { _ in throw Boom() }
        } catch is Boom {}
        #expect(await revoked.items == ["tok-1"])

        let existing = Recorder()
        let used = try await RealHostToken.with(
            environment: ["PURRDR_HTTPS_TOKEN": "mine"], pair: { "unused" }, revoke: { await existing.append($0) }) { $0 }
        #expect(used == "mine")
        #expect(await existing.items.isEmpty)
    }

    @Test("沒有配對碼也沒有權杖時丟錯")
    func missingCredentials() async {
        await #expect(throws: RealHostToken.Missing.self) {
            try await RealHostToken.with(environment: [:], pair: { "" }, revoke: { _ in }) { $0 }
        }
    }
}

private actor Recorder {
    var items: [String] = []
    func append(_ item: String) { items.append(item) }
}
