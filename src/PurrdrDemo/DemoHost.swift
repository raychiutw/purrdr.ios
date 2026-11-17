import Foundation
import PurrdrCore
import PurrdrSSH

/// Demo 主機(行為規格 F21):不連任何機器的主機通道。
///
/// 對真正 client 會送出的**精確指令字串**給出回應，所以每個畫面跑的都是正式程式路徑。
/// 沒有主機時它就是選取中主機——App Review 唯一連得到的東西——也是 UI 測試的資料來源。
/// 範例內容一律自己寫，不沿用 herdrchat 的文字(行為規格 D9)。
///
/// 目前內容：三個 Agent(「需要你」、工作中、已完成各一)、兩個 Claude Code agent 的對話紀錄(`DemoTranscripts`;
/// 送出 prompt 後接上使用者那一行與固定回覆，「需要你」的 agent 回 `agent_blocked`)、接受按鍵(中斷)、
/// 接受事件訂閱(不送事件)與在場回報、回顯的 shell、記憶體裡的家目錄(主機檔案讀寫;Claude 用量裝上後回範例用量)。
/// 完整的情境在 Demo 模式那張票補齊。
public actor DemoHost: HostChannel {
    /// Demo 主機的情境(UI 測試以啟動旗標切換)。
    public enum Scenario: Sendable, Equatable {
        case standard
        /// 桌機(或另一台裝置)正在操作 Demo 的 Pane:不帶 `--takeover` 會被拒。
        case paneInUse
        /// Tailscale SSH check mode:第一個指令先要求重新驗證(經 `tailscaleCheck` 回報)。
        case tailscaleCheck(completesAfter: Duration?)
        /// 對話畫面定位對話紀錄的指令不回應(直到關閉):停在對話載入中(#114)。列表預覽、subagent 照常回應。
        /// 讀取有期限(`HostCommandDeadline.standard`,20 秒):期限到了 client 關閉指令、畫面離開載入中，
        /// 所以只在進入對話後的這段時間內停在載入中。
        case transcriptPending
    }

    /// check mode 情境的驗證網址(不存在的示範網址)。
    public static let tailscaleCheckURL = URL(string: "https://login.tailscale.com/a/demo")!

    /// Demo 不建立 workspace、worktree、tab、split(行為規格 F3.1)。
    public static let unsupportedMessage = "The demo host can’t create workspaces or worktrees. Add your own host to try this."

    private let scenario: Scenario

    /// 送出 prompt 後各 session 接上的對話紀錄行(只在記憶體)。
    private var appended: [String: [String]] = [:]
    private var prompts = 0

    /// 這次啟動中對 workspace 做過的改動(重新命名、關閉)。只在記憶體裡，重開 app 就回到原樣。
    private var state = DemoSnapshot.State()

    /// 「需要你」情境的進度。
    private var answers = DemoAnswers()

    /// 記憶體裡的家目錄(主機檔案讀寫，例如 Claude 用量的同意與還原)。
    private var files = DemoFiles()

    /// 檔案瀏覽的資料夾(上傳只在記憶體)。
    private var folders = DemoFolders()

    private let tailscaleCheck: TailscaleCheckObserver?

    /// Demo 家目錄的上傳資料夾。
    static let uploadFolder = "/Users/demo/" + UploadedImages.folder

    public init(scenario: Scenario = .standard, tailscaleCheck: TailscaleCheckObserver? = nil) {
        self.scenario = scenario
        self.tailscaleCheck = tailscaleCheck
    }

    public func execute(_ command: String) async throws -> any ExecSession {
        try await passTailscaleCheck()
        if command == HerdrCommand.bridge() {
            return DemoBridgeSession { [weak self] line in
                guard let self else { return (Data(), false) }
                return await self.respond(to: line)
            }
        }
        if let upload = ImageUploadCommand.parse(command) {
            return DemoImageUploadSession(name: upload.name, size: upload.size)
        }
        if let control = DemoPaneControl(command: command) {
            return openPane(control)
        }
        if let stdout = DemoSlash.respond(to: command) {
            return DemoFinishedSession(events: [.stdout(stdout), .exit(code: 0)])
        }
        if scenario == .transcriptPending, DemoTranscripts.isLocate(command) {
            return DemoPendingSession()
        }
        if let stdout = DemoTranscripts.respond(to: command, appended: appended) {
            return DemoFinishedSession(events: [.stdout(stdout), .exit(code: 0)])
        }
        if let path = HostFolderCommand.parseList(command) {
            let result = folders.list(path)
            return DemoFinishedSession(events: (result.stdout.isEmpty ? [] : [.stdout(result.stdout)])
                + (result.stderr.isEmpty ? [] : [.stderr(result.stderr)]) + [.exit(code: result.exitCode)])
        }
        if let upload = HostFolderCommand.parseUpload(command) {
            return DemoUploadSession { [weak self] received in
                guard let self else { return (Data(), 70) }
                return await self.finishUpload(upload, received: received)
            }
        }
        if let listing = DemoNewChatFolders.respond(to: command) {
            return DemoFinishedSession(events: (listing.stdout.isEmpty ? [] : [.stdout(listing.stdout)]) + [.exit(code: listing.exitCode)])
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
        try await passTailscaleCheck()
        return DemoEchoShell()
    }

    // MARK: - Tailscale check mode 情境

    private var checkPassed = false
    private var checkWait: Task<Void, any Error>?

    /// check mode 情境：還沒驗證過就回報驗證網址並等待(`completesAfter` 後視為驗證完成;`nil` = 等到取消)。
    /// 同時的指令一起等同一次驗證;取消後下一個指令重新要求驗證。
    private func passTailscaleCheck() async throws {
        guard case .tailscaleCheck(let completesAfter) = scenario, !checkPassed else { return }
        let wait: Task<Void, any Error>
        if let checkWait {
            wait = checkWait
        } else {
            let cancel: @Sendable () async -> Void = { [weak self] in await self?.cancelTailscaleCheck() }
            wait = Task { [tailscaleCheck] in
                tailscaleCheck?(TailscaleCheckPrompt(url: Self.tailscaleCheckURL, cancel: cancel))
                defer { tailscaleCheck?(nil) }
                try await Task.sleep(for: completesAfter ?? .seconds(60 * 60))
            }
            checkWait = wait
        }
        do {
            try await wait.value
            checkPassed = true
        } catch {
            checkWait = nil
            throw SSHConnectionError.tailscaleCheckCancelled
        }
    }

    private func cancelTailscaleCheck() {
        checkWait?.cancel()
    }

    private func finishUpload(_ upload: FolderUpload, received: Int) -> (stdout: Data, exitCode: Int32) {
        folders.upload(upload, received: received)
    }

    /// `agent.prompt` 的回應：閒置的 Claude Code agent 收下後，對話紀錄接上新的行;不是 `agent.prompt` 回 `nil`。
    private func promptResponse(to requestLine: Data) -> (line: Data, keepsOpen: Bool)? {
        let request = (try? JSONSerialization.jsonObject(with: requestLine)) as? [String: Any]
        guard request?["method"] as? String == "agent.prompt" else { return nil }
        guard let params = request?["params"] as? [String: Any],
              let target = params["target"] as? String, let text = params["text"] as? String else {
            return DemoSnapshot.error(id: request?["id"] as? String ?? "", code: "invalid_request", message: "invalid params")
        }
        let id = request?["id"] as? String ?? ""
        if let rejection = answers.promptRejection(for: target) {
            // 在等回答的 agent:herdr 在送出任何輸入前就拒絕。
            return DemoSnapshot.error(id: id, code: rejection.code, message: rejection.message)
        }
        switch target {
        case "w1:p1", "w2:p1", "w3:p1":
            // 開面板的 slash 指令(`/model`)不寫進對話紀錄(Claude 的本地指令)。
            if !answers.receivedPrompt(text, paneID: target),
               let session = DemoTranscripts.sessions.first(where: { $0.paneID == target }) {
                prompts += 1
                appended[session.sessionID, default: []] += DemoTranscripts.reply(to: text, number: prompts, at: Date())
            }
            return DemoSnapshot.prompted(id: id, paneID: target)
        default:
            return DemoSnapshot.error(id: id, code: "agent_not_found", message: "agent not found: \(target)")
        }
    }

    /// 「桌機正在操作」的情境下，Pane 被別人佔著，直到有人接管。
    private lazy var paneHeldElsewhere = scenario == .paneInUse

    private func openPane(_ control: DemoPaneControl) -> any ExecSession {
        guard DemoPaneControl.knownTargets.contains(control.target) else {
            return DemoFinishedSession(events: [
                .stdout(DemoPaneSession.closedLine("terminal session control failed: terminal target \(control.target) not found")),
                .exit(code: 0),
            ])
        }
        if paneHeldElsewhere && !control.takeover {
            return DemoFinishedSession(events: [
                .stdout(DemoPaneSession.closedLine(
                    "terminal attach failed: terminal term_demo01 already has an attached client; retry with --takeover")),
                .exit(code: 0),
            ])
        }
        paneHeldElsewhere = false
        return DemoPaneSession(columns: control.columns, rows: control.rows)
    }

    private func respond(to requestLine: Data) -> (line: Data, keepsOpen: Bool) {
        if let response = promptResponse(to: requestLine) ?? paneResponse(to: requestLine) { return response }
        state.statuses = answers.statuses
        return DemoSnapshot.response(to: requestLine, state: &state)
    }

    /// `pane.read`(各 pane 畫面上的提示)、`pane.send_keys` 與 `pane.send_text`(回答提示)。其他請求回 `nil`。
    private func paneResponse(to requestLine: Data) -> (line: Data, keepsOpen: Bool)? {
        let request = (try? JSONSerialization.jsonObject(with: requestLine)) as? [String: Any]
        let id = request?["id"] as? String ?? ""
        let params = request?["params"] as? [String: Any] ?? [:]
        let paneID = params["pane_id"] as? String ?? ""
        switch request?["method"] as? String {
        case "pane.read":
            return DemoSnapshot.paneRead(id: id, paneID: paneID, text: answers.screen(for: paneID))
        case "pane.send_keys":
            answers.receivedKeys(params["keys"] as? [String] ?? [], paneID: paneID)
            return DemoSnapshot.ok(id: id)
        case "pane.send_text":
            answers.receivedText(params["text"] as? String ?? "", paneID: paneID)
            return DemoSnapshot.ok(id: id)
        default:
            return nil
        }
    }
}

// MARK: - Pane 終端機

/// 解析 `HerdrCommand.terminalSessionControl` 產生的指令。用解析出來的值重建一次並比對整個字串，
/// 確保 Demo 只回應 client 真正會送的精確指令。
struct DemoPaneControl {
    static let knownTargets: Set<String> = ["w1:p1", "term_demo01"]

    var target: String
    var columns: Int
    var rows: Int
    var takeover: Bool

    init?(command: String) {
        guard let range = command.range(of: " terminal session control '") else { return nil }
        let tail = command[range.upperBound...]
        guard let quoteEnd = tail.firstIndex(of: "'") else { return nil }
        let target = String(tail[..<quoteEnd])
        let options = tail[tail.index(after: quoteEnd)...].split(separator: " ")
        guard options.count >= 4, options[0] == "--cols", options[2] == "--rows",
              let columns = Int(options[1]), let rows = Int(options[3]) else { return nil }
        let takeover = options.count == 5 && options[4] == "--takeover"
        guard command == HerdrCommand.terminalSessionControl(target: target, columns: columns, rows: rows, takeover: takeover)
        else { return nil }
        self.target = target
        self.columns = columns
        self.rows = rows
        self.takeover = takeover
    }
}

/// Demo 的 Pane:一個會回顯的 shell,以 herdr `terminal session control` 的 NDJSON 格式輸出。
/// 認得 `ls`;其他指令回「command not found」。控制字元以 `^C`、`^[` 顯示，方便看出按鍵有送到遠端。
/// `terminal.scroll` 像一般 shell 一樣捲主機端 scrollback(開啟前已有一段 `python export.py` 的輸出)。
private actor DemoPaneSession: ExecSession {
    static let prompt = "demo@purrdr ledger % "

    nonisolated let output: AsyncThrowingStream<ExecOutput, any Error>
    private let continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation
    private var stdin = Data()
    private var seq: UInt64 = 0
    private var line = ""
    private var finished = false
    private var columns: Int
    private var rows: Int
    /// 主機端的畫面與 scrollback(最後一列是目前的 prompt 列)。
    private var lines: [String]
    /// 從底部往上捲了幾列(herdr 的 `offset_from_bottom`)。
    private var scrollOffset = 0

    /// 開啟前已經在 Pane 裡的輸出，讓終端機有東西可以捲回去看。
    static let earlierOutput = ["\(prompt)python export.py", "Reading ledger.csv"]
        + (1...60).map { "Exported row \($0) of 60" }
        + ["Wrote export/ledger-2026-11.csv"]

    init(columns: Int, rows: Int) {
        (output, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
        self.columns = columns
        self.rows = rows
        lines = Self.earlierOutput + [Self.prompt]
        seq = 1
        let bottom = lines.suffix(rows).joined(separator: "\r\n")
        continuation.yield(.stdout(Self.frameLine(seq: 1, columns: columns, rows: rows, full: true,
                                                  text: "\u{1B}[2J\u{1B}[H" + bottom)))
    }

    func write(_ data: Data) async throws {
        guard !finished else { return }
        stdin.append(data)
        while let newline = stdin.firstIndex(of: 0x0A) {
            let message = stdin[stdin.startIndex..<newline]
            stdin.removeSubrange(stdin.startIndex...newline)
            handle(message)
        }
    }

    func closeStdin() async { close(reason: "detached") }
    func close() async { close(reason: "detached") }

    private func handle(_ message: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "terminal.input":
            let bytes = (json["bytes"] as? String).flatMap { Data(base64Encoded: $0) }
                ?? Data((json["text"] as? String ?? "").utf8)
            let echo = render(bytes)
            guard !echo.isEmpty else { return }
            record(echo)
            if scrollOffset > 0 {
                // 跟 herdr 一樣：輸入把主機端 scrollback 捲回底部。
                scrollOffset = 0
                emit(full: false, text: viewport())
            } else {
                emit(full: false, text: echo)
            }
        case "terminal.resize":
            columns = json["cols"] as? Int ?? columns
            rows = json["rows"] as? Int ?? rows
            scrollOffset = min(scrollOffset, maxScrollOffset)
            emit(full: true, text: viewport())
        case "terminal.scroll":
            // 一般 shell:捲主機端 scrollback `lines` 列;沒有變化時不送 frame。
            let distance = max(1, json["lines"] as? Int ?? 1)
            let target = json["direction"] as? String == "up"
                ? min(scrollOffset + distance, maxScrollOffset)
                : max(scrollOffset - distance, 0)
            guard target != scrollOffset else { return }
            scrollOffset = target
            emit(full: false, text: viewport())
        case "terminal.release":
            close(reason: "detached")
        default:
            break
        }
    }

    /// 像 shell 的行編輯器一樣處理輸入，回傳要畫在畫面上的文字。
    private func render(_ bytes: Data) -> String {
        var echo = ""
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            switch scalar.value {
            case 0x0D:
                echo += "\r\n" + Self.run(line) + Self.prompt
                line = ""
            case 0x03:
                echo += "^C\r\n" + Self.prompt
                line = ""
            case 0x7F, 0x08:
                if !line.isEmpty {
                    line.removeLast()
                    echo += "\u{8} \u{8}"
                }
            case 0..<0x20:
                let caret = "^" + String(UnicodeScalar(UInt8(scalar.value) + 0x40))
                line += caret
                echo += caret
            default:
                line.unicodeScalars.append(scalar)
                echo.unicodeScalars.append(scalar)
            }
        }
        return echo
    }

    /// 把畫到畫面上的文字記進 `lines`(換行開新列，`\u{8} \u{8}` 刪一個字)。
    private func record(_ echo: String) {
        for (segmentIndex, segment) in echo.components(separatedBy: "\u{8} \u{8}").enumerated() {
            if segmentIndex > 0, !lines[lines.count - 1].isEmpty { lines[lines.count - 1].removeLast() }
            for (pieceIndex, piece) in segment.components(separatedBy: "\r\n").enumerated() {
                if pieceIndex > 0 { lines.append("") }
                lines[lines.count - 1] += piece
            }
        }
    }

    private var maxScrollOffset: Int { max(0, lines.count - rows) }

    /// 依捲動位置重畫整個 viewport;在底部時游標停在 prompt 結尾。
    private func viewport() -> String {
        let end = lines.count - scrollOffset
        let start = max(0, end - rows)
        return "\u{1B}[2J\u{1B}[H" + lines[start..<end].joined(separator: "\r\n")
    }

    private static func run(_ command: String) -> String {
        switch command.trimmingCharacters(in: .whitespaces) {
        case "": ""
        case "ls": "README.md  export.py  ledger.csv\r\n"
        case let other: "zsh: command not found: \(other.split(separator: " ").first ?? "")\r\n"
        }
    }

    private func emit(full: Bool, text: String) {
        seq += 1
        continuation.yield(.stdout(Self.frameLine(seq: seq, columns: columns, rows: rows, full: full, text: text)))
    }

    private func close(reason: String) {
        guard !finished else { return }
        finished = true
        continuation.yield(.stdout(Self.closedLine(reason)))
        continuation.yield(.exit(code: 0))
        continuation.finish()
    }

    private static func frameLine(seq: UInt64, columns: Int, rows: Int, full: Bool, text: String) -> Data {
        let bytes = Data(text.utf8).base64EncodedString()
        return Data(#"{"bytes":"\#(bytes)","encoding":"ansi","full":\#(full),"height":\#(rows),"seq":\#(seq),"type":"terminal.frame","width":\#(columns)}"#.utf8) + [0x0A]
    }

    static func closedLine(_ reason: String) -> Data {
        Data(#"{"reason":"\#(reason)","type":"terminal.closed"}"#.utf8) + [0x0A]
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
        /// 依「需要你」情境改過的 Agent 狀態(pane id → 狀態)。
        var statuses: [String: String] = [:]
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
        case "pane.report_metadata":
            return (line(#"{"id":\#(quoted(id)),"result":{"type":"ok"}}"#), false)
        case "events.subscribe":
            // Demo 的內容不會變，所以只接受訂閱、不送事件。
            return (line(#"{"id":\#(quoted(id)),"result":{"type":"subscription_started"}}"#), true)
        case let method?:
            return (line(#"{"id":\#(quoted(id)),"error":{"code":"unknown_method","message":"unknown method: \#(method)"}}"#), false)
        case nil:
            return (line(#"{"id":"","error":{"code":"invalid_request","message":"invalid request"}}"#), false)
        }
    }

    static func error(id: String, code: String, message: String) -> (line: Data, keepsOpen: Bool) {
        (line(#"{"id":\#(quoted(id)),"error":{"code":\#(quoted(code)),"message":\#(quoted(message))}}"#), false)
    }

    /// `agent.prompt` 成功(`agent_prompted`,形狀依 `herdr api schema --json`,只放 client 會看的欄位)。
    static func prompted(id: String, paneID: String) -> (line: Data, keepsOpen: Bool) {
        (line(#"{"id":\#(quoted(id)),"result":{"type":"agent_prompted","agent":{"pane_id":\#(quoted(paneID)),"agent_status":"working"}}}"#), false)
    }

    /// `pane.read` 的結果(形狀依錄製的 `pane.read.visible.ndjson`)。
    static func paneRead(id: String, paneID: String, text: String) -> (line: Data, keepsOpen: Bool) {
        let read: [String: Any] = [
            "pane_id": paneID, "workspace_id": String(paneID.prefix { $0 != ":" }), "source": "visible", "format": "text",
            "text": text, "revision": 0, "truncated": false,
        ]
        return (result(id: id, ["type": "pane_read", "read": read]), false)
    }

    static func ok(id: String) -> (line: Data, keepsOpen: Bool) {
        (line(#"{"id":\#(quoted(id)),"result":{"type":"ok"}}"#), false)
    }

    private static let workspaceIDs: Set<String> = ["w1", "w2", "w3"]

    /// 範例 snapshot 套上這次啟動中的改動：關掉的 workspace 連同 tab、pane、版面、Agent 一起拿掉;改過的名稱換掉。
    private static func snapshot(applying state: State) -> [String: Any] {
        guard var snapshot = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return [:] }
        for key in ["workspaces", "tabs", "panes", "layouts", "agents"] {
            snapshot[key] = (snapshot[key] as? [[String: Any]])?.filter { !state.closed.contains($0["workspace_id"] as? String ?? "") }
        }
        for key in ["agents", "panes"] {
            snapshot[key] = (snapshot[key] as? [[String: Any]])?.map { item in
                var item = item
                if let pane = item["pane_id"] as? String, let status = state.statuses[pane] { item["agent_status"] = status }
                return item
            }
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

/// 圖片上傳：收 stdin 到 EOF,大小相符就回上傳資料夾的路徑(內容不保存)。大小不符(上傳中斷)時失敗。
private final class DemoImageUploadSession: ExecSession, @unchecked Sendable {
    let output: AsyncThrowingStream<ExecOutput, any Error>
    private let continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation
    private let lock = NSLock()
    private var received = 0
    private var finished = false
    private let name: UploadFileName
    private let size: Int

    init(name: UploadFileName, size: Int) {
        self.name = name
        self.size = size
        (output, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
    }

    func write(_ data: Data) async throws {
        lock.withLock { received += data.count }
    }

    func closeStdin() async {
        let (count, done) = lock.withLock {
            defer { finished = true }
            return (received, finished)
        }
        guard !done else { return }
        if count == size {
            continuation.yield(.stdout(Data("\(DemoHost.uploadFolder)/\(name.value)\n".utf8)))
            continuation.yield(.exit(code: 0))
        } else {
            continuation.yield(.exit(code: 75))
        }
        continuation.finish()
    }

    func close() async {
        lock.withLock { finished = true }
        continuation.finish()
    }
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

/// 一直不回應、直到關閉才結束的指令。
private struct DemoPendingSession: ExecSession {
    let output: AsyncThrowingStream<ExecOutput, any Error>
    private let continuation: AsyncThrowingStream<ExecOutput, any Error>.Continuation

    init() {
        (output, continuation) = AsyncThrowingStream<ExecOutput, any Error>.makeStream()
    }

    func write(_ data: Data) async throws {}
    func closeStdin() async {}
    func close() async { continuation.finish() }
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
