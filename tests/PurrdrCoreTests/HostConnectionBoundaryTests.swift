import Foundation
import Testing

/// 上層功能(Agent 列表、對話閱讀、送 prompt、Pane 終端機)只依賴主機連線(#54、ADR-0010)。
///
/// Features 另有登入 Shell、推播外掛這些只有 SSH 才有的功能，得依賴主機通道，所以 target 擋不住;
/// 這個測試擋住上層功能直接拿主機通道建 herdr client、對話紀錄讀取或 Pane 終端機。
@Suite("主機連線邊界")
struct HostConnectionBoundaryTests {
    static let upperLayerFiles = [
        "AgentListModel.swift", "MergedAgentListModel.swift", "ConversationModel.swift", "PaneTerminalModel.swift",
        "SubagentModel.swift", "WorkflowModel.swift", "WorkspaceActionsModel.swift",
    ]
    static let channelOnlyClients = ["HerdrClient(channel:", "TranscriptReader(channel:", "PaneTerminalClient(channel:"]

    static var featuresDirectory: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures")
    }

    @Test("Features 只從主機連線建立 herdr client、對話紀錄讀取與 Pane 終端機")
    func featuresBuildClientsFromHostConnection() throws {
        let files = FileManager.default.enumerator(at: Self.featuresDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty, "沒有掃到任何原始碼，路徑可能錯了")
        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for client in Self.channelOnlyClients where source.contains(client) {
                violations.append("\(file.lastPathComponent): \(client)")
            }
        }
        #expect(violations.isEmpty, "上層功能直接用主機通道:\(violations)")
    }

    @Test("上層功能的畫面 model 不提到主機通道")
    func upperLayerModelsDoNotMentionHostChannel() throws {
        for name in Self.upperLayerFiles {
            let source = try String(contentsOf: Self.featuresDirectory.appending(path: name), encoding: .utf8)
            for word in ["HostChannel", "ExecSession", "PTYSession"] {
                #expect(!source.contains(word), "\(name) 提到 \(word)")
            }
        }
    }
}
