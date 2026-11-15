import Foundation
import PurrdrCore

/// Demo 主機(行為規格 F21):不連任何機器的主機通道。
///
/// 對真正 client 會送出的**精確指令字串**給出回應，所以每個畫面跑的都是正式程式路徑。
/// 沒有主機時它就是選取中主機——App Review 唯一連得到的東西——也是 UI 測試的資料來源。
/// 範例內容一律自己寫，不沿用 herdrchat 的文字(行為規格 D9)。
///
/// 目前內容：三個 Agent(「需要你」、工作中、已完成各一)、接受事件訂閱(不送事件)、回顯的 shell。
/// 完整的情境在 Demo 模式那張票補齊。
public actor DemoHost: HostChannel {
    /// Demo 不建立 workspace、worktree、tab、split(行為規格 F3.1)。
    public static let unsupportedMessage = "The demo host can’t create workspaces or worktrees. Add your own host to try this."

    /// 這次啟動中對 workspace 做過的改動(重新命名、關閉)。只在記憶體裡，重開 app 就回到原樣。
    private var state = DemoSnapshot.State()

    public init() {}

    public func execute(_ command: String) async throws -> any ExecSession {
        if command == HerdrCommand.bridge() {
            return DemoBridgeSession { [weak self] line in
                guard let self else { return (Data(), false) }
                return await self.respond(to: line)
            }
        }
        let program = command.split(separator: " ").first.map(String.init) ?? command
        return DemoFinishedSession(events: [
            .stderr(Data("sh: \(program): command not found\n".utf8)),
            .exit(code: 127),
        ])
    }

    public func openPTY(_ request: PTYRequest) async throws -> any PTYSession {
        DemoEchoShell()
    }

    private func respond(to requestLine: Data) -> (line: Data, keepsOpen: Bool) {
        DemoSnapshot.response(to: requestLine, state: &state)
    }
}

// MARK: - 範例資料

enum DemoSnapshot {
    /// herdr 0.9.5(protocol 22)`session.snapshot` 的形狀，內容是自己寫的範例。
    static let json = #"""
    {"version":"0.9.5","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1",\#
    "workspaces":[\#
    {"workspace_id":"w1","number":1,"label":"ledger","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"done"},\#
    {"workspace_id":"w2","number":2,"label":"weather-app","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w2:t1","agent_status":"blocked"},\#
    {"workspace_id":"w3","number":3,"label":"notes","focused":false,"pane_count":2,"tab_count":1,"active_tab_id":"w3:t1","agent_status":"working"}],\#
    "tabs":[\#
    {"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1","focused":true,"pane_count":1,"agent_status":"done"},\#
    {"tab_id":"w2:t1","workspace_id":"w2","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"blocked"},\#
    {"tab_id":"w3:t1","workspace_id":"w3","number":1,"label":"1","focused":false,"pane_count":2,"agent_status":"working"}],\#
    "panes":[\#
    {"pane_id":"w1:p1","terminal_id":"term_demo01","workspace_id":"w1","tab_id":"w1:t1","focused":true,\#
    "cwd":"/Users/demo/ledger","foreground_cwd":"/Users/demo/ledger","agent":"claude",\#
    "terminal_title":"✳ Tidy up the CSV export","terminal_title_stripped":"Tidy up the CSV export","agent_status":"done",\#
    "agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"d3m0d3m0-0000-4000-8000-000000000001"},\#
    "scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":32},"revision":1},\#
    {"pane_id":"w2:p1","terminal_id":"term_demo02","workspace_id":"w2","tab_id":"w2:t1","focused":false,\#
    "cwd":"/Users/demo/weather-app","foreground_cwd":"/Users/demo/weather-app","agent":"claude",\#
    "terminal_title":"✳ Cache the hourly forecast","terminal_title_stripped":"Cache the hourly forecast","agent_status":"blocked",\#
    "agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"d3m0d3m0-0000-4000-8000-000000000002"},\#
    "scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":32},"revision":1},\#
    {"pane_id":"w3:p1","terminal_id":"term_demo03","workspace_id":"w3","tab_id":"w3:t1","focused":false,\#
    "cwd":"/Users/demo/notes","foreground_cwd":"/Users/demo/notes","agent":"codex",\#
    "terminal_title":"Sync notes to Markdown | notes","terminal_title_stripped":"Sync notes to Markdown | notes","agent_status":"working",\#
    "scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":32},"revision":1},\#
    {"pane_id":"w3:p2","terminal_id":"term_demo04","workspace_id":"w3","tab_id":"w3:t1","focused":false,\#
    "cwd":"/Users/demo/notes","foreground_cwd":"/Users/demo/notes",\#
    "terminal_title":"npm run dev","terminal_title_stripped":"npm run dev","agent_status":"unknown",\#
    "scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":32},"revision":1}],\#
    "layouts":[\#
    {"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"area":{"x":0,"y":0,"width":160,"height":40},"focused_pane_id":"w1:p1",\#
    "panes":[{"pane_id":"w1:p1","focused":true,"rect":{"x":0,"y":0,"width":160,"height":40}}],"splits":[]},\#
    {"workspace_id":"w2","tab_id":"w2:t1","zoomed":false,"area":{"x":0,"y":0,"width":160,"height":40},"focused_pane_id":"w2:p1",\#
    "panes":[{"pane_id":"w2:p1","focused":true,"rect":{"x":0,"y":0,"width":160,"height":40}}],"splits":[]},\#
    {"workspace_id":"w3","tab_id":"w3:t1","zoomed":false,"area":{"x":0,"y":0,"width":160,"height":40},"focused_pane_id":"w3:p1",\#
    "panes":[{"pane_id":"w3:p1","focused":true,"rect":{"x":0,"y":0,"width":96,"height":40}},\#
    {"pane_id":"w3:p2","focused":false,"rect":{"x":96,"y":0,"width":64,"height":40}}],\#
    "splits":[{"id":"w3:s1","direction":"vertical","ratio":0.6,"rect":{"x":0,"y":0,"width":160,"height":40}}]}],\#
    "agents":[\#
    {"terminal_id":"term_demo01","agent":"claude",\#
    "terminal_title":"✳ Tidy up the CSV export","terminal_title_stripped":"Tidy up the CSV export","agent_status":"done",\#
    "agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"d3m0d3m0-0000-4000-8000-000000000001"},\#
    "workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"state_change_seq":2,"completion_seq":2,\#
    "cwd":"/Users/demo/ledger","foreground_cwd":"/Users/demo/ledger","revision":1},\#
    {"terminal_id":"term_demo02","agent":"claude",\#
    "terminal_title":"✳ Cache the hourly forecast","terminal_title_stripped":"Cache the hourly forecast","agent_status":"blocked",\#
    "agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"d3m0d3m0-0000-4000-8000-000000000002"},\#
    "workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p1","focused":false,"state_change_seq":4,\#
    "cwd":"/Users/demo/weather-app","foreground_cwd":"/Users/demo/weather-app","revision":1},\#
    {"terminal_id":"term_demo03","agent":"codex",\#
    "terminal_title":"Sync notes to Markdown | notes","terminal_title_stripped":"Sync notes to Markdown | notes","agent_status":"working",\#
    "workspace_id":"w3","tab_id":"w3:t1","pane_id":"w3:p1","focused":false,"state_change_seq":3,\#
    "cwd":"/Users/demo/notes","foreground_cwd":"/Users/demo/notes","revision":1}]}
    """#

    /// 這次啟動中對 workspace 做過的改動。
    struct State {
        var labels: [String: String] = [:]
        var closed: Set<String> = []
    }

    /// 依 socket API 的請求產生一行回應(`{id,result}` 或 `{id,error}`)。
    /// `keepsOpen` 為 `true` 時(`events.subscribe`)回應後串流保持開著，像真的訂閱一樣等事件。
    static func response(to requestLine: Data, state: inout State) -> (line: Data, keepsOpen: Bool) {
        let request = (try? JSONSerialization.jsonObject(with: requestLine)) as? [String: Any]
        let id = request?["id"] as? String ?? ""
        let method = request?["method"] as? String
        let params = request?["params"] as? [String: Any] ?? [:]
        switch method {
        case "session.snapshot":
            return (result(id: id, ["type": "session_snapshot", "snapshot": snapshot(applying: state)]), false)
        case "workspace.rename", "workspace.close":
            guard let workspaceID = params["workspace_id"] as? String, workspaceIDs.contains(workspaceID),
                  !state.closed.contains(workspaceID) else {
                let missing = params["workspace_id"] as? String ?? ""
                return (line(#"{"id":\#(quoted(id)),"error":{"code":"workspace_not_found","message":\#(quoted("workspace \(missing) not found"))}}"#), false)
            }
            if method == "workspace.close" {
                state.closed.insert(workspaceID)
                return (result(id: id, ["type": "ok"]), false)
            }
            state.labels[workspaceID] = params["label"] as? String ?? ""
            let workspace = (snapshot(applying: state)["workspaces"] as? [[String: Any]])?.first { $0["workspace_id"] as? String == workspaceID }
            return (result(id: id, ["type": "workspace_info", "workspace": workspace ?? [:]]), false)
        case "workspace.create", "worktree.create", "tab.create", "pane.split":
            return (line(#"{"id":\#(quoted(id)),"error":{"code":"demo_unsupported","message":\#(quoted(DemoHost.unsupportedMessage))}}"#), false)
        case "events.subscribe":
            // Demo 的內容不會變，所以只接受訂閱、不送事件。
            return (line(#"{"id":\#(quoted(id)),"result":{"type":"subscription_started"}}"#), true)
        case let method?:
            return (line(#"{"id":\#(quoted(id)),"error":{"code":"unknown_method","message":"unknown method: \#(method)"}}"#), false)
        case nil:
            return (line(#"{"id":"","error":{"code":"invalid_request","message":"invalid request"}}"#), false)
        }
    }

    private static let workspaceIDs: Set<String> = ["w1", "w2", "w3"]

    /// 範例 snapshot 套上這次啟動中的改動：關掉的 workspace 連同 tab、pane、版面、Agent 一起拿掉;改過的名稱換掉。
    private static func snapshot(applying state: State) -> [String: Any] {
        guard var snapshot = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return [:] }
        for key in ["workspaces", "tabs", "panes", "layouts", "agents"] {
            snapshot[key] = (snapshot[key] as? [[String: Any]])?.filter { !state.closed.contains($0["workspace_id"] as? String ?? "") }
        }
        snapshot["workspaces"] = (snapshot["workspaces"] as? [[String: Any]])?.map { workspace in
            var workspace = workspace
            if let id = workspace["workspace_id"] as? String, let label = state.labels[id] { workspace["label"] = label }
            return workspace
        }
        return snapshot
    }

    private static func result(id: String, _ result: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: ["id": id, "result": result], options: [.sortedKeys])) ?? Data()
        return data + [0x0A]
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    private static func line(_ text: String) -> Data { Data(text.utf8) + [0x0A] }
}

// MARK: - session

/// `herdr remote-api-bridge`:讀到一行請求才回應;stdin 一行都沒收到就 EOF 時什麼都不回(與真的 bridge 相同)。
private actor DemoBridgeSession: ExecSession {
    nonisolated let output: AsyncThrowingStream<ExecOutput, any Error>
    private let continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation
    private let respond: @Sendable (Data) async -> (line: Data, keepsOpen: Bool)
    private var stdin = Data()
    private var answered = false

    init(respond: @escaping @Sendable (Data) async -> (line: Data, keepsOpen: Bool)) {
        (output, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
        self.respond = respond
    }

    func write(_ data: Data) async throws {
        guard !answered else { return }
        stdin.append(data)
        guard let newline = stdin.firstIndex(of: 0x0A) else { return }
        answered = true
        let response = await respond(Data(stdin[stdin.startIndex..<newline]))
        continuation.yield(.stdout(response.line))
        guard !response.keepsOpen else { return }
        continuation.yield(.exit(code: 0))
        continuation.finish()
    }

    func closeStdin() async {
        guard !answered else { return }
        answered = true
        continuation.yield(.exit(code: 0))
        continuation.finish()
    }

    func close() async { continuation.finish() }
}

/// 一開始就結束的指令。
private struct DemoFinishedSession: ExecSession {
    let output: AsyncThrowingStream<ExecOutput, any Error>

    init(events: [ExecOutput]) {
        output = AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func write(_ data: Data) async throws {}
    func closeStdin() async {}
    func close() async {}
}

/// 回顯輸入的 shell。
private struct DemoEchoShell: PTYSession {
    let output: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init() {
        (output, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(Data("demo@purrdr ~ % ".utf8))
    }

    func write(_ data: Data) async throws { continuation.yield(data) }
    func resize(columns: Int, rows: Int) async throws {}
    func close() async { continuation.finish() }
}
