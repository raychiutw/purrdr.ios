#if os(macOS)
import Foundation
import PurrdrCore
@testable import PurrdrSSH
import PurrdrTestSupport
import Testing

/// 偵測主機上裝了哪些 Agent(#477):看家目錄裡各 Agent 的設定資料夾在不在(唯讀)。
@Suite("偵測主機上的 Agent")
struct HostAgentDetectorTests {
    @Test("有設定資料夾的 Agent 算裝了,沒有的不算")
    func detectsByConfigurationFolder() async throws {
        let host = FakeHost()
        await host.serveHomeFiles(directories: [".claude", ".gemini", ".gemini/antigravity-cli"])
        let detected = try await HostAgentDetector(files: HostFiles(channel: host)).installedAgents()
        #expect(detected == [.claude, .agy])
    }

    @Test("只有上層資料夾(.gemini)不算裝了 Antigravity")
    func parentFolderIsNotEnough() async throws {
        let host = FakeHost()
        await host.serveHomeFiles(directories: [".gemini"])
        #expect(try await HostAgentDetector(files: HostFiles(channel: host)).installedAgents().isEmpty)
    }

    @Test("連不上主機:丟出錯誤,不當作一個都沒裝(呼叫端下次再偵測)")
    func connectionFailureThrows() async {
        let host = FakeHost()
        await host.failConnection(with: FakeHostError.unexpectedCommand("down"))
        await #expect(throws: (any Error).self) {
            _ = try await HostAgentDetector(files: HostFiles(channel: host)).installedAgents()
        }
    }
}
#endif
