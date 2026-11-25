import Foundation
import Testing

/// modal 的工具列規則(#613、spec #612):關閉一律左上 X(`SheetCloseToolbar`),右上關閉的元件不存在;
/// 有確認動作的 modal 右上是唯一的 ✓(`ModalConfirmToolbar`)。
@Suite("Modal 工具列用法")
struct ModalToolbarUsageTests {
    private static let featuresFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src/PurrdrFeatures")

    private static func sources() throws -> [(name: String, text: String)] {
        let enumerator = try #require(FileManager.default.enumerator(at: featuresFolder, includingPropertiesForKeys: nil))
        var result: [(name: String, text: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(result.count > 10, "找不到 src/PurrdrFeatures 的原始碼")
        return result
    }

    @Test("沒有右上關閉的元件，也沒有 role: .close 的按鈕")
    func noTrailingClose() throws {
        var violations: [String] = []
        for (name, text) in try Self.sources() {
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("TrailingCloseToolbar") || line.contains("role: .close") {
                violations.append("\(name):\(index + 1)")
            }
        }
        #expect(violations.isEmpty, "關閉一律用左上的 SheetCloseToolbar:\n\(violations.joined(separator: "\n"))")
    }

    @Test("有確認動作的 modal 右上用 ModalConfirmToolbar")
    func confirmModalsUseSharedToolbar() throws {
        let required = ["HostTrustView.swift", "ChangesView.swift", "WorkspaceActionsViews.swift", "MemberView.swift"]
        let sources = try Self.sources()
        for file in required {
            let text = try #require(sources.first { $0.name == file }?.text, "找不到 \(file)")
            #expect(text.contains("ModalConfirmToolbar"), "\(file) 的確認動作要用 ModalConfirmToolbar")
        }
    }

    @Test("信任主機、行評論、新增 worktree 不再自己放文字的 Cancel 與確認鈕")
    func noHandMadeConfirmation() throws {
        let sources = try Self.sources()
        for file in ["HostTrustView.swift", "ChangesView.swift", "WorkspaceActionsViews.swift"] {
            let text = try #require(sources.first { $0.name == file }?.text)
            #expect(!text.contains("ToolbarItem(placement: .confirmationAction)"), "\(file) 不自己放 confirmationAction")
        }
    }
}
