import Foundation
import PurrdrCore

/// Demo 主機(行為規格 F21):不連任何機器的主機通道。
///
/// 對真正 client 會送出的**精確指令字串**給出回應，所以每個畫面跑的都是正式程式路徑。
/// 沒有主機時它就是選取中主機——App Review 唯一連得到的東西——也是 UI 測試的資料來源。
/// 範例內容一律自己寫，不沿用 herdrchat 的文字(行為規格 D9)。
///
/// 目前內容：三個 Agent(「需要你」、工作中、已完成各一)、接受事件訂閱(不送事件)、回顯的 shell、
/// 記憶體裡的家目錄(主機檔案讀寫;Claude 用量裝上後回範例用量)。
/// 完整的情境在 Demo 模式那張票補齊。
public actor DemoHost: HostChannel {
    /// 記憶體裡的家目錄(主機檔案讀寫，例如 Claude 用量的同意與還原)。
    private var files = DemoFiles()

    public init() {}

    public func execute(_ command: String) async throws -> any ExecSession {
        if command == HerdrCommand.bridge() {
            return DemoBridgeSession()
        }
        if let request = HostFileRequest(command: command) {
            let result = files.handle(request, now: Date())
            return DemoFinishedSession(events: (result.stdout.isEmpty ? [] : [.stdout(result.stdout)]) + [.exit(code: result.exitCode)])
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
}

// MARK: - 範例資料

enum DemoSnapshot {
    /// herdr 0.9.5(protocol 22)`session.snapshot` 的形狀，內容是自己寫的範例。
    static let json = #"""
    {"version":"0.9.5","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1",\#
    "workspaces":[\#
    {"workspace_id":"w1","number":1,"label":"ledger","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"done"},\#
    {"workspace_id":"w2","number":2,"label":"weather-app","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w2:t1","agent_status":"blocked"},\#
    {"workspace_id":"w3","number":3,"label":"notes","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w3:t1","agent_status":"working"}],\#
    "tabs":[\#
    {"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1","focused":true,"pane_count":1,"agent_status":"done"},\#
    {"tab_id":"w2:t1","workspace_id":"w2","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"blocked"},\#
    {"tab_id":"w3:t1","workspace_id":"w3","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"working"}],\#
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
    "scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":32},"revision":1}],\#
    "layouts":[],\#
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

    /// 依 socket API 的請求產生一行回應(`{id,result}` 或 `{id,error}`)。
    /// `keepsOpen` 為 `true` 時(`events.subscribe`)回應後串流保持開著，像真的訂閱一樣等事件。
    static func response(to requestLine: Data) -> (line: Data, keepsOpen: Bool) {
        let request = (try? JSONSerialization.jsonObject(with: requestLine)) as? [String: Any]
        let id = request?["id"] as? String ?? ""
        let method = request?["method"] as? String
        switch method {
        case "session.snapshot":
            return (line(#"{"id":\#(quoted(id)),"result":{"type":"session_snapshot","snapshot":\#(json)}}"#), false)
        case "events.subscribe":
            // Demo 的內容不會變，所以只接受訂閱、不送事件。
            return (line(#"{"id":\#(quoted(id)),"result":{"type":"subscription_started"}}"#), true)
        case let method?:
            return (line(#"{"id":\#(quoted(id)),"error":{"code":"unknown_method","message":"unknown method: \#(method)"}}"#), false)
        case nil:
            return (line(#"{"id":"","error":{"code":"invalid_request","message":"invalid request"}}"#), false)
        }
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
    private var stdin = Data()
    private var answered = false

    init() {
        (output, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
    }

    func write(_ data: Data) async throws {
        guard !answered else { return }
        stdin.append(data)
        guard let newline = stdin.firstIndex(of: 0x0A) else { return }
        answered = true
        let response = DemoSnapshot.response(to: stdin[stdin.startIndex..<newline])
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
