import Foundation

/// 從真實主機錄下的回應(`scripts/record-herdr-fixture.sh`,說明見 `Fixtures/README.md`)。
public enum Fixtures {
    public static let defaultHerdrVersion = "0.9.5"

    /// 讀一份錄製檔的原始 bytes。找不到就直接當掉：測試寫錯檔名要立刻看到。
    public static func data(_ name: String, herdr version: String = defaultHerdrVersion) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/herdr-\(version)"),
              let data = try? Data(contentsOf: url) else {
            fatalError("找不到錄製檔 Fixtures/herdr-\(version)/\(name)")
        }
        return data
    }

    /// `herdr terminal session control`／`observe` 的錄製檔(`Fixtures/herdr-<版本>/session-control/<名稱>`,#4 spike)。
    public static func sessionControl(_ name: String, herdr version: String = defaultHerdrVersion) -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: nil, subdirectory: "Fixtures/herdr-\(version)/session-control"
        ), let data = try? Data(contentsOf: url) else {
            fatalError("找不到錄製檔 Fixtures/herdr-\(version)/session-control/\(name)")
        }
        return data
    }

    /// 錄製檔逐行切開(不含換行)。
    public static func sessionControlLines(_ name: String, herdr version: String = defaultHerdrVersion) -> [Data] {
        sessionControl(name, herdr: version).split(separator: 0x0A).map { Data($0) }
    }

    /// 錄製檔第一行的 JSON,經 `modify` 改動後再序列化成一行(結尾換行)。
    public static func modifiedLine(_ name: String, herdr version: String = defaultHerdrVersion, modify: (inout [String: Any]) -> Void) -> Data {
        let data = data(name, herdr: version)
        let firstLine = data.split(separator: 0x0A).first ?? data[...]
        guard var object = (try? JSONSerialization.jsonObject(with: firstLine)) as? [String: Any] else {
            fatalError("錄製檔 \(name) 第一行不是 JSON 物件")
        }
        modify(&object)
        guard let line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            fatalError("改動後的 \(name) 無法序列化")
        }
        return line + [0x0A]
    }

    /// 從真實 Claude Code 對話紀錄擷取、去識別化的檔案(`Fixtures/claude-code/<名稱>`)。
    public static func transcript(_ name: String = "session.jsonl") -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/claude-code"),
              let data = try? Data(contentsOf: url) else {
            fatalError("找不到對話紀錄 Fixtures/claude-code/\(name)")
        }
        return data
    }

    /// 去識別化的 subagent 檔(`Fixtures/claude-code/subagents/<名稱>`:meta 與對話紀錄)。
    public static func subagentFile(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/claude-code/subagents"),
              let data = try? Data(contentsOf: url) else {
            fatalError("找不到 Fixtures/claude-code/subagents/\(name)")
        }
        return data
    }

    /// Workflow 的 run 檔與 journal(`Fixtures/claude-code/workflow/<名稱>`)。依行為規格 §4.6 寫成，不是錄製的
    /// (作者 Mac 上沒有 workflow 紀錄)。
    public static func workflowFile(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/claude-code/workflow"),
              let data = try? Data(contentsOf: url) else {
            fatalError("找不到 Fixtures/claude-code/workflow/\(name)")
        }
        return data
    }

    /// 對話紀錄的每一行(不含換行)。
    public static func transcriptLines(_ name: String = "session.jsonl") -> [String] {
        transcript(name).split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 對話紀錄的第 `index` 行(從 0 起算),先以 `modify` 改動其中的 JSON。用在錄不到的情境(改了什麼寫在測試裡)。
    public static func transcriptLine(_ index: Int, of name: String = "session.jsonl", modify: (inout [String: Any]) -> Void) -> String {
        let lines = transcriptLines(name)
        guard lines.indices.contains(index),
              var object = (try? JSONSerialization.jsonObject(with: Data(lines[index].utf8))) as? [String: Any] else {
            fatalError("對話紀錄 \(name) 沒有第 \(index) 行或不是 JSON 物件")
        }
        modify(&object)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            fatalError("改動後的第 \(index) 行無法序列化")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 錄製檔中的某一行(從 0 起算),含結尾換行。用來把串流錄製檔拆開逐行推送。
    public static func line(_ index: Int, of name: String, herdr version: String = defaultHerdrVersion) -> Data {
        let lines = data(name, herdr: version).split(separator: 0x0A)
        guard lines.indices.contains(index) else { fatalError("錄製檔 \(name) 沒有第 \(index) 行") }
        return Data(lines[index]) + [0x0A]
    }
}

/// 改動 `session.snapshot` 回應的小工具(搭配 `FakeReply.recorded(_:modify:)`)。
public enum SnapshotEdit {
    /// 改 `pane_id` 為 `paneID` 的那個 agent(在 `agents[]` 與 `panes[]` 兩處都改)。
    public static func agent(_ paneID: String, in response: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        editSnapshot(&response) { snapshot in
            for key in ["agents", "panes"] {
                guard var items = snapshot[key] as? [[String: Any]] else { continue }
                for index in items.indices where items[index]["pane_id"] as? String == paneID {
                    change(&items[index])
                }
                snapshot[key] = items
            }
        }
    }

    /// 改 `workspace_id` 為 `workspaceID` 的 workspace。
    public static func workspace(_ workspaceID: String, in response: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        editSnapshot(&response) { snapshot in
            guard var items = snapshot["workspaces"] as? [[String: Any]] else { return }
            for index in items.indices where items[index]["workspace_id"] as? String == workspaceID {
                change(&items[index])
            }
            snapshot["workspaces"] = items
        }
    }

    /// 移除 `pane_id` 為 `paneID` 的 agent 與 pane(例如 pane 在主機上被關掉)。
    public static func removeAgent(_ paneID: String, in response: inout [String: Any]) {
        editSnapshot(&response) { snapshot in
            for key in ["agents", "panes"] {
                snapshot[key] = (snapshot[key] as? [[String: Any]])?.filter { $0["pane_id"] as? String != paneID }
            }
        }
    }

    private static func editSnapshot(_ response: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        guard var result = response["result"] as? [String: Any], var snapshot = result["snapshot"] as? [String: Any] else {
            fatalError("不是 session.snapshot 的回應")
        }
        change(&snapshot)
        result["snapshot"] = snapshot
        response["result"] = result
    }
}
