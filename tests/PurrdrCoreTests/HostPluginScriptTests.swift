#if os(macOS)
import Foundation
import PurrdrCore
import PurrdrTestSupport
import Testing

/// 主機外掛(`host-plugin/`,ADR-0004)的 POSIX 腳本：herdr 在 `pane.agent_status_changed` 時以新程序執行它。
///
/// 以 `LocalShellHost` 在暫存家目錄真的執行 `host-plugin/notify.sh`,herdr 給的環境變數照 herdr 文件
/// (`HERDR_PLUGIN_EVENT`、`HERDR_PLUGIN_EVENT_JSON`、`HERDR_PLUGIN_CONTEXT_JSON`、`HERDR_BIN_PATH`)手動帶入;
/// `curl` 與 `herdr` 換成家目錄 `bin/` 裡的假程式，記錄收到的參數與 stdin,不連網路、不碰真的 herdr。
@Suite("主機外掛腳本")
struct HostPluginScriptTests {
    static let pluginDirectory = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "host-plugin")
    static let endpoint = "https://backend.test/v1/push"
    static let keyA = String(repeating: "ab", count: 32)
    static let keyB = String(repeating: "cd", count: 32)

    /// herdr 序列化的事件 envelope(`EventEnvelope`:`event` 是 snake_case、`data` 以 `type` 標記)。
    /// `title` 是終端機標題，可能帶對話內容——外掛不能送出它。
    static func event(status: String, pane: String = "w2:p1") -> String {
        #"{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"\#(pane)","workspace_id":"w2","agent_status":"\#(status)","agent":"claude","title":"Delete \"prod\" database? secret-plan","display_agent":"Claude"}}"#
    }

    static func context(label: String = "weather-app") -> String {
        #"{"workspace_id":"w2","workspace_label":"\#(label)","focused_pane_id":"w2:p1","focused_pane_agent":"claude","focused_pane_status":"blocked","correlation_id":"evt-1"}"#
    }

    let host: LocalShellHost

    init() throws {
        host = try LocalShellHost.temporary()
        try installFake("curl", """
            #!/bin/sh
            n=$(ls "$HOME/curl-calls" 2>/dev/null | wc -l | tr -d ' ')
            mkdir -p "$HOME/curl-calls/$n"
            printf '%s\\n' "$@" > "$HOME/curl-calls/$n/args"
            cat > "$HOME/curl-calls/$n/stdin"

            """)
        // `herdr pane get <pane>`:回傳該 pane 的 agent session(錄自 herdr 0.9.5 的 `pane list` 欄位形狀)。
        try installFake("herdr", """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$HOME/herdr-calls"
            if [ "$1 $2" = "pane get" ]; then
              printf '%s\\n' '{"id":"cli:pane:get","result":{"pane":{"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"session-weather"},"agent_status":"blocked","pane_id":"w2:p1","workspace_id":"w2"},"type":"pane_info"}}'
            fi

            """)
    }

    func installFake(_ name: String, _ script: String) throws {
        let url = try host.write(Data(script.utf8), to: "bin/\(name)")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func pair(device: String, key: String, muted: [String] = []) throws {
        let file = PushPairingFile(endpoint: URL(string: Self.endpoint)!, key: PushPairingKey(hex: key)!, muted: Set(muted))
        try host.write(file.contents, to: ".purrdr/push-\(device)/pairing")
    }

    /// 以 herdr 的方式執行外掛：新程序、帶事件環境變數。
    @discardableResult
    func runHook(event: String, context: String = HostPluginScriptTests.context()) async throws -> Int32 {
        let environment = [
            "HERDR_ENV=1",
            "HERDR_PLUGIN_ID=purrdr.push",
            "HERDR_PLUGIN_EVENT=pane.agent_status_changed",
            "HERDR_PLUGIN_EVENT_JSON=\(PosixShell.quote(event))",
            "HERDR_PLUGIN_CONTEXT_JSON=\(PosixShell.quote(context))",
            #"HERDR_BIN_PATH="$HOME/bin/herdr""#,
            #"PATH="$HOME/bin:$PATH""#,
        ].joined(separator: " ")
        let script = PosixShell.quote(Self.pluginDirectory.appending(path: "notify.sh").path)
        let session = try await host.execute("cd \(PosixShell.quote(Self.pluginDirectory.path)) && \(environment) sh \(script)")
        var code: Int32 = -1
        for try await output in session.output {
            if case .exit(let exit, _) = output { code = exit }
        }
        return code
    }

    struct CurlCall {
        var arguments: [String]
        var body: [String: Any]
        var rawBody: String
    }

    func curlCalls() throws -> [CurlCall] {
        let directory = host.url("curl-calls")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted().map { name in
            let raw = try String(contentsOf: directory.appending(path: "\(name)/stdin"), encoding: .utf8)
            let arguments = try String(contentsOf: directory.appending(path: "\(name)/args"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let body = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
            return CurlCall(arguments: arguments, body: body, rawBody: raw)
        }
    }

    @Test("Agent 進入「需要你」:帶配對密鑰呼叫後台，內容只有 workspace 名稱、狀態與 pane")
    func blockedNotifiesBackend() async throws {
        try pair(device: "a1", key: Self.keyA)

        #expect(try await runHook(event: Self.event(status: "blocked")) == 0)

        let calls = try curlCalls()
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.arguments.last == Self.endpoint)
        #expect(Set(call.body.keys) == ["key", "workspace", "status", "pane"])
        #expect(call.body["key"] as? String == Self.keyA)
        #expect(call.body["workspace"] as? String == "weather-app")
        #expect(call.body["status"] as? String == "blocked")
        #expect(call.body["pane"] as? String == "w2:p1")
    }

    @Test("推播請求不含終端機標題等對話內容")
    func requestCarriesNoConversationContent() async throws {
        try pair(device: "a1", key: Self.keyA)

        try await runHook(event: Self.event(status: "blocked"))

        let call = try #require(try curlCalls().first)
        #expect(!call.rawBody.contains("secret-plan"))
        #expect(!call.rawBody.contains("prod"))
        #expect(!call.rawBody.contains("Claude"))
    }

    @Test("配對密鑰經 stdin 交給 curl,不出現在指令參數(其他使用者用 ps 看得到參數)")
    func keyIsNotInArguments() async throws {
        try pair(device: "a1", key: Self.keyA)

        try await runHook(event: Self.event(status: "blocked"))

        let call = try #require(try curlCalls().first)
        #expect(!call.arguments.joined(separator: " ").contains(Self.keyA))
        #expect(call.arguments.contains("--max-time"))
    }

    @Test("其他狀態(工作中、完成、閒置)不通知", arguments: ["working", "done", "idle", "unknown"])
    func otherStatusesDoNothing(status: String) async throws {
        try pair(device: "a1", key: Self.keyA)

        #expect(try await runHook(event: Self.event(status: status)) == 0)

        #expect(try curlCalls().isEmpty)
    }

    @Test("沒有推播配對時什麼都不做")
    func noPairingDoesNothing() async throws {
        #expect(try await runHook(event: Self.event(status: "blocked")) == 0)
        #expect(try curlCalls().isEmpty)
    }

    @Test("一台主機配對多支裝置：每支各送一次，用各自的密鑰")
    func everyPairedDeviceIsNotified() async throws {
        try pair(device: "a1", key: Self.keyA)
        try pair(device: "b2", key: Self.keyB)

        try await runHook(event: Self.event(status: "blocked"))

        #expect(Set(try curlCalls().compactMap { $0.body["key"] as? String }) == [Self.keyA, Self.keyB])
    }

    @Test("某支裝置靜音了這個聊天(session):只跳過那支裝置")
    func mutedChatSkipsThatDevice() async throws {
        try pair(device: "a1", key: Self.keyA, muted: ["session-weather"])
        try pair(device: "b2", key: Self.keyB, muted: ["session-other"])

        try await runHook(event: Self.event(status: "blocked"))

        #expect(try curlCalls().compactMap { $0.body["key"] as? String } == [Self.keyB])
        let herdrCalls = try String(contentsOf: host.url("herdr-calls"), encoding: .utf8)
        #expect(herdrCalls.contains("pane get w2:p1"))
    }

    @Test("沒有任何靜音時不必問 herdr")
    func withoutMutesHerdrIsNotAsked() async throws {
        try pair(device: "a1", key: Self.keyA)

        try await runHook(event: Self.event(status: "blocked"))

        #expect(!FileManager.default.fileExists(atPath: host.url("herdr-calls").path))
    }

    @Test("workspace 名稱含引號與反斜線時仍送出合法 JSON,名稱不變")
    func workspaceLabelEscapesSurvive() async throws {
        try pair(device: "a1", key: Self.keyA)

        try await runHook(event: Self.event(status: "blocked"), context: Self.context(label: #"my \"app\" \\ 天氣"#))

        let call = try #require(try curlCalls().first)
        #expect(call.body["workspace"] as? String == #"my "app" \ 天氣"#)
    }

    @Test("沒有 workspace 名稱時用 workspace id")
    func missingLabelFallsBackToWorkspaceID() async throws {
        try pair(device: "a1", key: Self.keyA)

        try await runHook(event: Self.event(status: "blocked"), context: #"{"workspace_id":"w2"}"#)

        #expect(try curlCalls().first?.body["workspace"] as? String == "w2")
    }

    @Test("pane id 形狀不對時不送 pane")
    func malformedPaneIsOmitted() async throws {
        try pair(device: "a1", key: Self.keyA)

        try await runHook(event: Self.event(status: "blocked", pane: "w2:p1;rm"))

        let call = try #require(try curlCalls().first)
        #expect(call.body["pane"] == nil)
    }

    @Test("manifest:只掛 pane.agent_status_changed,macOS／Linux 用 sh、Windows 用 PowerShell 腳本(檔案都在)")
    func manifestDeclaresHooks() throws {
        let manifest = try String(contentsOf: Self.pluginDirectory.appending(path: "herdr-plugin.toml"), encoding: .utf8)
        #expect(manifest.contains(#"id = "\#(PushHost.pluginID)""#))
        #expect(manifest.contains(#"on = "pane.agent_status_changed""#))
        #expect(manifest.contains(#"command = ["sh", "notify.sh"]"#))
        #expect(manifest.contains("notify.ps1"))
        #expect(FileManager.default.fileExists(atPath: Self.pluginDirectory.appending(path: "notify.ps1").path))
    }
}
#endif
