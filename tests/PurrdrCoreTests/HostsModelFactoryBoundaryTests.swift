import Foundation
import Testing

/// 主機清單 model 只管清單、選取與同步(#564):畫面 model 的工廠在每台主機的成員(`HostMember`)與 `HostScreens` 上。
@Suite("主機清單不建立畫面 model")
struct HostsModelFactoryBoundaryTests {
    /// 這些畫面 model 不能由 `HostsModel.swift` 建立。
    static let screenModels = [
        "ConversationModel(", "NewChatModel(", "PaneTerminalModel(", "LoginShellModel(", "FolderBrowserModel(", "PlanUsageModel(",
        "UsageSectionModel(", "DataUsageModel(", "HostPickerModel(", "HostEditorModel(", "AddHostGuideModel(", "HostAgentSettingsModel(",
    ]

    @Test("HostsModel.swift 沒有建立任何畫面 model")
    func hostsModelBuildsNoScreenModels() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "src/PurrdrFeatures/HostsModel.swift"), encoding: .utf8)
        let found = Self.screenModels.filter { source.contains($0) }
        #expect(found.isEmpty, "HostsModel 還在建立:\(found)")
    }
}
