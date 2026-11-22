import Foundation
import Testing

/// 容器加 `.accessibilityIdentifier` 前要先 `.accessibilityElement(children: .contain)`,否則 identifier 會蓋掉子元素的 identifier。
@Suite("容器的 accessibility identifier")
struct AccessibilityContainerIdentifierTests {
    /// 裡面還有自己 identifier 的子元素的容器(檔名、identifier)。
    static let containers: [(file: String, identifier: String)] = [
        ("PlusCardView.swift", "account.plusCard"),
        ("ImageViewer.swift", "imageViewer"),
        ("PairingCodeScanner.swift", "scanner.denied"),
        ("AgentListView.swift", "agentList.offline"),
    ]

    @Test("容器的 identifier 前一律有 children: .contain", arguments: containers)
    func containerKeepsChildIdentifiers(file: String, identifier: String) throws {
        let featuresFolder = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures")
        let source = try String(contentsOf: featuresFolder.appending(path: file), encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let identifierLine = try #require(
            lines.firstIndex { $0.contains(".accessibilityIdentifier(\"\(identifier)\")") },
            "\(file) 沒有 \(identifier)"
        )
        let precedingModifiers = lines[max(0, identifierLine - 3)..<identifierLine]
        #expect(
            precedingModifiers.contains { $0.contains(".accessibilityElement(children: .contain)") },
            "\(file) 的 \(identifier) 前要加 .accessibilityElement(children: .contain)"
        )
    }
}
