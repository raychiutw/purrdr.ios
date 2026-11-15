import Foundation
import PurrdrCore

/// Demo 主機(行為規格 F21):不連任何機器的主機通道。
///
/// 對真正 client 會送出的**精確指令字串**給出回應，所以每個畫面跑的都是正式程式路徑。
/// 沒有主機時它就是選取中主機——App Review 唯一連得到的東西——也是 UI 測試的資料來源。
/// 範例內容一律自己寫，不沿用 herdrchat 的文字(行為規格 D9)。
///
/// 目前只有最小內容：一個 Claude Code 的 Agent、回顯的 shell。完整的情境在 Demo 模式那張票補齊。
public actor DemoHost: HostChannel {
    public init() {}

    public func execute(_ command: String) async throws -> any ExecSession {
        if command == HerdrCommand.bridge() {
            return DemoBridgeSession()
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
    "workspaces":[{"workspace_id":"w1","number":1,"label":"ledger","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"done"}],\#
    "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"1","focused":true,"pane_count":1,"agent_status":"done"}],\#
    "panes":[{"pane_id":"w1:p1","terminal_id":"term_demo01","workspace_id":"w1","tab_id":"w1:t1","focused":true,\#
    "cwd":"/Users/demo/ledger","foreground_cwd":"/Users/demo/ledger","agent":"claude",\#
    "terminal_title":"✳ Tidy up the CSV export","terminal_title_stripped":"Tidy up the CSV export","agent_status":"done",\#
    "agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"d3m0d3m0-0000-4000-8000-000000000001"},\#
    "scroll":{"offset_from_bottom":0,"max_offset_from_bottom":0,"viewport_rows":32},"revision":1}],\#
    "layouts":[],\#
    "agents":[{"terminal_id":"term_demo01","agent":"claude",\#
    "terminal_title":"✳ Tidy up the CSV export","terminal_title_stripped":"Tidy up the CSV export","agent_status":"done",\#
    "agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"d3m0d3m0-0000-4000-8000-000000000001"},\#
    "workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"state_change_seq":2,"completion_seq":2,\#
    "cwd":"/Users/demo/ledger","foreground_cwd":"/Users/demo/ledger","revision":1}]}
    """#

    /// 依 socket API 的請求產生一行回應(`{id,result}` 或 `{id,error}`)。
    static func response(to requestLine: Data) -> Data {
        let request = (try? JSONSerialization.jsonObject(with: requestLine)) as? [String: Any]
        let id = request?["id"] as? String ?? ""
        let method = request?["method"] as? String
        switch method {
        case "session.snapshot":
            return line(#"{"id":\#(quoted(id)),"result":{"type":"session_snapshot","snapshot":\#(json)}}"#)
        case let method?:
            return line(#"{"id":\#(quoted(id)),"error":{"code":"unknown_method","message":"unknown method: \#(method)"}}"#)
        case nil:
            return line(#"{"id":"","error":{"code":"invalid_request","message":"invalid request"}}"#)
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
        continuation.yield(.stdout(DemoSnapshot.response(to: stdin[stdin.startIndex..<newline])))
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
