import Foundation
import Testing

/// 清單裡的一般動作列不被 app 主色染色(#638、spec #634):SwiftUI 的 List 會把 Button 自動染成主色,
/// 動作列要明確 `.listAction()`(文字主要色、圖示次要色)。原始碼守門,prior art:`ProminentFillUsageTests`。
@Suite("清單動作列顏色用法")
struct ListActionColorUsageTests {
    /// 盤點出的清單動作列(accessibilityIdentifier 前綴;`.listAction()` 必須在該按鈕的修飾鏈上)。
    static let actionRowIdentifiers = [
        "settings.welcome", "settings.rate", "settings.support", "settings.copyDiagnostics", "settings.privacy",
        "settings.hitchLog.share", "plus.manage", "plus.restore", "plus.redeem", "member.signOut",
        "member.deleteSubscription.manage", "hosts.notifications.signIn", "settings.push.plus",
        "settings.push.openSettings", "settings.hostSync.retry", "hostStatus.hostService.retry",
        "settings.youShouldKnow.undo", "hostServiceUpdate.copy.", "\\(identifier).copy.", "deviceKey.copy", "deviceKey.copyCommand.", "hostEditor.replaceKey",
        "hostEditor.useDeviceKey", "hostEditor.test", "welcome.addHost", "welcome.rate",
    ]

    private static func featureSources() throws -> [(name: String, lines: [String])] {
        let folder = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures")
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var result: [(String, [String])] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            result.append((url.lastPathComponent, source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)))
        }
        #expect(result.count > 10, "找不到 src/PurrdrFeatures 的原始碼")
        return result
    }

    @Test("盤點出的清單動作列都套 listAction")
    func actionRowsUseListAction() throws {
        let sources = try Self.featureSources()
        var violations: [String] = []
        for identifier in Self.actionRowIdentifiers {
            var found = false
            for (name, lines) in sources {
                for (index, line) in lines.enumerated() where line.contains("\"\(identifier)\"") || (identifier.hasSuffix(".") && line.contains("\"\(identifier)")) {
                    found = true
                    let window = lines[max(0, index - 3) ... min(lines.count - 1, index + 1)]
                    if !window.contains(where: { $0.contains(".listAction()") }) {
                        violations.append("\(name):\(index + 1) \(identifier)")
                    }
                }
            }
            if !found { violations.append("找不到 \(identifier)(盤點清單過期?)") }
        }
        #expect(violations.isEmpty, "清單動作列要加 .listAction():\n\(violations.joined(separator: "\n"))")
    }

    @Test("帳號與設定頁的一般 Button 都套 listAction")
    func settingsButtonsUseListAction() throws {
        let sources = try Self.featureSources()
        let settings = try #require(sources.first { $0.name == "SettingsView.swift" })
        var violations: [String] = []
        for (index, line) in settings.lines.enumerated() where line.contains("Button(") && !line.contains("role:") {
            let window = settings.lines[index ... min(settings.lines.count - 1, index + 12)]
            if !window.contains(where: { $0.contains(".listAction()") }) {
                violations.append("SettingsView.swift:\(index + 1)")
            }
        }
        #expect(violations.isEmpty, "設定頁的動作 Button 要加 .listAction():\n\(violations.joined(separator: "\n"))")
    }

    @Test("破壞性按鈕不套 listAction(紅色另由 destructiveText 規則管)")
    func destructiveButtonsKeepTheirOwnColor() throws {
        var violations: [String] = []
        for (name, lines) in try Self.featureSources() {
            for (index, line) in lines.enumerated() where line.contains("Button(") && line.contains("role: .destructive") {
                let window = lines[index ... min(lines.count - 1, index + 3)]
                if window.contains(where: { $0.contains(".listAction()") }) {
                    violations.append("\(name):\(index + 1)")
                }
            }
        }
        #expect(violations.isEmpty, "破壞性按鈕不要用 .listAction():\n\(violations.joined(separator: "\n"))")
    }
}
