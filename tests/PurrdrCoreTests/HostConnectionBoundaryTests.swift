import Foundation
import Testing

/// 上層功能(Agent 列表、對話閱讀、送 prompt、Pane 終端機)只依賴主機連線(#54、#89、ADR-0010)。
///
/// 依賴方向由 target 強制：上層功能在 `PurrdrAgentFeatures`,它只依賴 `PurrdrCore`,看不到主機通道(`PurrdrSSH`);
/// `swift build --build-system native --explicit-target-dependency-import-check error` 擋住沒宣告依賴的 import(預設的 Swift Build 不擋)。
/// 這個測試只確認上層功能的畫面 model 放在那個 target、那個 target 沒有 import 主機通道。
@Suite("主機連線邊界")
struct HostConnectionBoundaryTests {
    static let upperLayerFiles = [
        "AgentListModel.swift", "MergedAgentListModel.swift", "ConversationModel.swift", "PaneTerminalModel.swift",
        "SubagentModel.swift", "WorkflowModel.swift", "WorkspaceActionsModel.swift",
    ]
    /// 上層功能不能 import 的 module:主機通道與 SSH 專屬功能。
    static let forbiddenModules: Set<String> = ["PurrdrSSH", "PurrdrFeatures", "PurrdrDemo"]
    static let channelOnlyClients = ["HerdrClient(channel:", "TranscriptReader(channel:", "PaneTerminalClient(channel:"]

    static var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func sources(in target: String) -> [URL] {
        FileManager.default.enumerator(at: root.appending(path: target), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    }

    @Test("上層功能的畫面 model 放在 PurrdrAgentFeatures")
    func upperLayerModelsLiveInAgentFeatures() {
        let names = Set(Self.sources(in: "src/PurrdrAgentFeatures").map(\.lastPathComponent))
        let misplaced = Self.upperLayerFiles.filter { !names.contains($0) }
        #expect(misplaced.isEmpty, "不在 src/PurrdrAgentFeatures:\(misplaced)")
    }

    @Test("PurrdrAgentFeatures 不 import 主機通道與 SSH 專屬功能")
    func agentFeaturesDoNotImportHostChannel() throws {
        let files = Self.sources(in: "src/PurrdrAgentFeatures")
        #expect(!files.isEmpty, "沒有掃到任何原始碼，路徑可能錯了")
        var violations: [String] = []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                guard let module = PortableCoreImportTests.importedModule(in: String(line)) else { continue }
                if Self.forbiddenModules.contains(module) || line.contains("@_exported") {
                    violations.append("\(file.lastPathComponent): \(line)")
                }
            }
        }
        #expect(violations.isEmpty, "上層功能看得到主機通道:\(violations)")
    }

    @Test("核心不轉出主機通道")
    func coreDoesNotReexport() throws {
        let files = Self.sources(in: "src/PurrdrCore")
        let reexports = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("@_exported") }
        #expect(reexports.isEmpty, "PurrdrCore 轉出了其他 module:\(reexports.map(\.lastPathComponent))")
    }

    @Test("畫面一律從主機連線建立 herdr client、對話紀錄讀取與 Pane 終端機")
    func featuresBuildClientsFromHostConnection() throws {
        let files = Self.sources(in: "src/PurrdrFeatures") + Self.sources(in: "src/PurrdrAgentFeatures")
        #expect(!files.isEmpty, "沒有掃到任何原始碼，路徑可能錯了")
        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for client in Self.channelOnlyClients where source.contains(client) {
                violations.append("\(file.lastPathComponent): \(client)")
            }
        }
        #expect(violations.isEmpty, "畫面直接用主機通道建 client:\(violations)")
    }
}
