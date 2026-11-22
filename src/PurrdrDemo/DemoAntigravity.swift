import Foundation
import PurrdrCore

/// Antigravity 的 Demo 內容(#446):`-demoAntigravity` 情境多一個 Antigravity Agent「garden」(w4:p1)。
///
/// 對話紀錄是 agy 1.5.14 真實格式(`USER_INPUT`、`PLANNER_RESPONSE`、`GENERIC`),畫面是真實錄製的閒置畫面改成假資料
/// (accept-edits 模式、Gemini 4 Neon · medium)。範例內容自己寫。
enum DemoAntigravity {
    static let paneID = "w4:p1"
    static let workspaceID = "w4"
    static let conversationID = "d3m0a9a9-0000-4000-8000-000000000004"
    static let cwd = "/Users/demo/garden"

    static let session = DemoTranscripts.Session(
        sessionID: conversationID, cwd: cwd, paneID: paneID,
        lines: [
            userInput(0, "2026-11-16T10:00:00Z", "Add a watering schedule for the tomatoes to schedule.md"),
            planner(1, "2026-11-16T10:00:02Z", model: "gemini-4-neon-medium", input: 3120, cacheRead: 0, output: 210,
                    thinking: "Checking the existing notes before writing the schedule.",
                    tools: [["name": "read_file", "args": ["Path": "\"/Users/demo/garden/schedule.md\""]]]),
            generic(2, "2026-11-16T10:00:04Z", "Showing lines 1-2 of 2\n1: # Garden schedule\n2: - Basil: every 2 days"),
            planner(3, "2026-11-16T10:00:06Z", model: "gemini-4-neon-medium", input: 3480, cacheRead: 2800, output: 96,
                    tools: [["name": "edit_file", "args": [
                        "Path": "\"/Users/demo/garden/schedule.md\"", "Target": "\"- Basil: every 2 days\"",
                        "Replacement": "\"- Basil: every 2 days\\n- Tomatoes: daily at dawn\"",
                    ]]]),
            generic(4, "2026-11-16T10:00:09Z", "The file has been updated."),
            planner(5, "2026-11-16T10:00:11Z", model: "gemini-4-neon-medium", input: 3600, cacheRead: 5100, output: 64,
                    text: "Added **Tomatoes: daily at dawn** to `schedule.md`."),
        ], isAntigravity: true)

    /// 閒置畫面(真實錄製 `agy-idle-accept-edits` 的結構):右下角「accept-edits · Gemini 4 Neon · medium」。
    static let screen = """
              ▄▀▀▄        Antigravity CLI 1.5.14
             ▀▀▀▀▀▀       demo@example.com (Google AI Pro)
            ▀▀▀▀▀▀▀▀      Gemini 4 Neon (Medium)
           ▄▀▀    ▀▀▄     /Users/demo/garden

        ──────────────────────────────────────────────────────────────────────────────────────────────────
        > Accept-edits mode: file edits auto-approved (shift+tab to cycle)
        ──────────────────────────────────────────────────────────────────────────────────────────────────
        ? for shortcuts                                              accept-edits · Gemini 4 Neon · medium
        """

    /// 送出 prompt 後接在對話紀錄後面的行:`!` 指令與一般訊息都只回示範說明。
    static func reply(to prompt: String, number: Int, startingAt step: Int, at date: Date) -> [String] {
        let timestamp = ISO8601DateFormatter().string(from: date)
        let later = ISO8601DateFormatter().string(from: date.addingTimeInterval(2))
        return [
            userInput(step, timestamp, prompt),
            planner(step + 1, later, model: "gemini-4-neon-medium", input: 3700, cacheRead: 5200, output: 40, text: """
            This is the demo host, so nothing actually ran. On your own computer, the agent would pick up your message \
            and its reply would appear here.
            """),
        ]
    }

    /// 範例 snapshot 的 w4 項目(workspace、tab、pane、版面、agent)。
    static var snapshotEntries: [String: [[String: Any]]] {
        let session: [String: Any] = ["source": "herdr:antigravity_cli", "agent": "agy", "kind": "id", "value": conversationID]
        let scroll: [String: Any] = ["offset_from_bottom": 0, "max_offset_from_bottom": 0, "viewport_rows": 32]
        return [
            "workspaces": [[
                "workspace_id": workspaceID, "number": 4, "label": "garden", "focused": false, "pane_count": 1, "tab_count": 1,
                "active_tab_id": "w4:t1", "agent_status": "done",
            ]],
            "tabs": [[
                "tab_id": "w4:t1", "workspace_id": workspaceID, "number": 1, "label": "1", "focused": false, "pane_count": 1,
                "agent_status": "done",
            ]],
            "panes": [[
                "pane_id": paneID, "terminal_id": "term_demo05", "workspace_id": workspaceID, "tab_id": "w4:t1", "focused": false,
                "cwd": cwd, "foreground_cwd": cwd, "agent": "agy", "terminal_title": "Garden watering schedule",
                "terminal_title_stripped": "Garden watering schedule", "agent_status": "done", "agent_session": session, "scroll": scroll,
                "revision": 1,
            ]],
            "layouts": [[
                "workspace_id": workspaceID, "tab_id": "w4:t1", "zoomed": false, "area": ["x": 0, "y": 0, "width": 160, "height": 40],
                "focused_pane_id": paneID,
                "panes": [["pane_id": paneID, "focused": true, "rect": ["x": 0, "y": 0, "width": 160, "height": 40]]], "splits": [],
            ]],
            "agents": [[
                "terminal_id": "term_demo05", "agent": "agy", "terminal_title": "Garden watering schedule",
                "terminal_title_stripped": "Garden watering schedule", "agent_status": "done", "agent_session": session,
                "workspace_id": workspaceID, "tab_id": "w4:t1", "pane_id": paneID, "focused": false, "state_change_seq": 5,
                "cwd": cwd, "foreground_cwd": cwd, "revision": 1,
            ]],
        ]
    }

    // MARK: - 行

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func userInput(_ step: Int, _ createdAt: String, _ text: String) -> String {
        json([
            "step_index": step, "source": "USER_EXPLICIT", "type": "USER_INPUT", "status": "DONE", "created_at": createdAt,
            "content": "<USER_REQUEST>\n\(text)\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: \(createdAt).\n</ADDITIONAL_METADATA>",
        ])
    }

    private static func planner(
        _ step: Int, _ createdAt: String, model: String, input: Int, cacheRead: Int, output: Int, text: String? = nil,
        thinking: String? = nil, tools: [[String: Any]]? = nil
    ) -> String {
        var object: [String: Any] = [
            "step_index": step, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "created_at": createdAt,
            "model": model, "input_tokens": input, "cache_read_tokens": cacheRead, "output_tokens": output,
        ]
        if let text { object["content"] = text }
        if let thinking { object["thinking"] = thinking }
        if let tools { object["tool_calls"] = tools }
        return json(object)
    }

    private static func generic(_ step: Int, _ createdAt: String, _ output: String) -> String {
        json([
            "step_index": step, "source": "MODEL", "type": "GENERIC", "status": "DONE", "created_at": createdAt,
            "content": "Created At: \(createdAt)\nCompleted At: \(createdAt)\n\(output)",
        ])
    }
}
