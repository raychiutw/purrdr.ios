import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

@Suite("herdr client(經主機通道)")
struct HerdrClientTests {
    /// 非互動 SSH shell 不讀 profile,herdr 常不在 PATH:一律前綴明確 PATH(行為規格 §3.2)。
    static let bridgeCommand =
        #"PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH" 'herdr' remote-api-bridge"#

    @Test("主機指令：bridge 指令前綴 PATH,herdr 路徑以單引號引起來")
    func bridgeCommandPrefixesPathAndQuotesHerdr() {
        #expect(HerdrCommand.bridge() == Self.bridgeCommand)
        #expect(HerdrCommand.bridge(HerdrInstallation(path: "/opt/my herdr/it's")) ==
            #"PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH" '/opt/my herdr/it'"'"'s' remote-api-bridge"#)
        // 引號內的 `~` 不會展開(exit 127):只把開頭的 `~/` 換成家目錄。
        #expect(HerdrCommand.bridge(HerdrInstallation(path: "~/.local/bin/herdr")).hasSuffix(#" "$HOME"/'.local/bin/herdr' remote-api-bridge"#))
    }

    @Test("讀 snapshot:對 bridge 送一行 session.snapshot 請求，解出錄製回應裡的每個 Agent")
    func snapshotDecodesRecordedAgents() async throws {
        let host = FakeHost()
        await host.expect(Self.bridgeCommand, reply: .recorded("session.snapshot.ndjson"))

        let snapshot = try await HerdrClient(channel: host).snapshot()

        let executions = await host.executions
        #expect(executions.map(\.command) == [Self.bridgeCommand])
        #expect(executions.first?.stdinText == #"{"id":"purrdr:session.snapshot","method":"session.snapshot","params":{}}"# + "\n")
        #expect(snapshot.version == "0.9.5")
        #expect(snapshot.agents == [
            Agent(paneID: "w1:p6", workspaceID: "w1", kind: "claude", status: .idle,
                  terminalTitle: "整理植物照片的標籤", workspaceLabel: "garden-journal", cwd: "/Users/demo/Projects/garden-journal"),
            Agent(paneID: "w1:pA", workspaceID: "w1", kind: "claude", status: .working,
                  terminalTitle: "規劃天氣小工具", workspaceLabel: "garden-journal", cwd: "/Users/demo/Projects"),
            Agent(paneID: "w1:pB", workspaceID: "w1", kind: "claude", status: .working,
                  terminalTitle: "重構食譜匯入", workspaceLabel: "garden-journal", cwd: "/Users/demo/Projects/recipe-box"),
        ])
    }

    @Test("bridge 規則：請求送出後不送 EOF,讀到回應後由 app 關閉通道")
    func bridgeKeepsStdinOpenUntilResponse() async throws {
        let host = FakeHost()
        await host.expect(Self.bridgeCommand, reply: .recorded("session.snapshot.ndjson"))

        _ = try await HerdrClient(channel: host).snapshot()

        let execution = try #require(await host.executions.first)
        #expect(execution.closedStdin == false)
        #expect(execution.closed == true)
    }

    @Test("herdr 回錯誤 envelope 時，以 herdr 的錯誤碼與原文失敗")
    func herdrErrorEnvelopeKeepsCodeAndMessage() async {
        let host = FakeHost()
        await host.expect(Self.bridgeCommand, reply: .recorded("error.invalid-request.ndjson"))

        await #expect(throws: HerdrError.herdr(code: "invalid_request", message: "invalid request: key must be a string at line 1 column 56")) {
            try await HerdrClient(channel: host).snapshot()
        }
    }

    @Test("bridge 沒有任何回應就結束時，帶上 exit code 與 stderr 失敗")
    func bridgeWithoutResponseReportsExitAndStderr() async {
        let host = FakeHost()
        let stderr = "failed to connect to remote Herdr API socket"
        await host.expect(Self.bridgeCommand, reply: FakeReply(stderr: Data(stderr.utf8), exitCode: 1))

        await #expect(throws: HerdrError.noResponse(exitCode: 1, stderr: stderr)) {
            try await HerdrClient(channel: host).snapshot()
        }
    }
}
