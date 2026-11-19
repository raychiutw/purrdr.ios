import Foundation
import Testing

/// 可攜核心(PurrdrCore、PurrdrSSH、PurrdrHTTPS、PurrdrDemo,ADR-0006)只能 import Foundation 與 swift-nio／swift-nio-ssh／swift-crypto 系列。
///
/// CI 的 Android 交叉編譯 job 已拿掉(ADR-0006 的更新),這個測試(`swift test`,CI 也跑)是目前唯一的守門:
/// 擋得到核心 import 了 SwiftUI、Security 或 os,擋不到「Apple 平台有、Android 的 Foundation 沒有」的 API。
@Suite("可攜核心")
struct PortableCoreImportTests {
    static let portableTargets = ["src/PurrdrCore", "src/PurrdrSSH", "src/PurrdrHTTPS", "src/PurrdrDemo"]
    static let allowedModules: Set<String> = [
        "Foundation", "FoundationEssentials", "FoundationNetworking", "Dispatch", "Synchronization",
        "NIO", "NIOCore", "NIOPosix", "NIOSSH", "NIOConcurrencyHelpers", "NIOFoundationCompat", "Crypto",
        "PurrdrCore", "PurrdrSSH", "PurrdrHTTPS", "PurrdrDemo",
    ]

    @Test("可攜核心不 import 任何 Apple 專屬 framework")
    func portableTargetsImportOnlyPortableModules() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var violations: [String] = []
        var scanned = 0
        for target in Self.portableTargets {
            let directory = root.appending(path: target)
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                scanned += 1
                guard let modules = Self.importedModules(inSource: try String(contentsOf: file, encoding: .utf8)) else {
                    violations.append("\(target)/\(file.lastPathComponent): 多行字串的分隔符號不成對，無法確認 import")
                    continue
                }
                for module in modules where !Self.allowedModules.contains(module) {
                    violations.append("\(target)/\(file.lastPathComponent): import \(module)")
                }
            }
        }
        #expect(scanned > 0, "沒有掃到任何原始碼，路徑可能錯了")
        #expect(violations.isEmpty, "可攜核心 import 了不可攜的 module:\(violations)")
    }

    @Test("多行字串裡的 import 文字不是 import 宣告;字串結束後的 import 照樣檢查")
    func importTextInsideMultilineStringIsNotADeclaration() {
        let source = """
        import Foundation
        static let sample = \"\"\"
            import Testing
            @testable import Ledger
            \"\"\"
        import SwiftUI
        """
        #expect(Self.importedModules(inSource: source) == ["Foundation", "SwiftUI"])
    }

    @Test("多行字串沒有結束時回報無法確認，不默默略過後面的程式碼")
    func unbalancedMultilineStringIsReported() {
        let source = """
        let script = \"\"\"
        import SwiftUI
        """
        #expect(Self.importedModules(inSource: source) == nil)
    }

    /// 原始碼的 import 宣告(頂層 module 名稱),略過多行字串(`"""` 之間)的內容;`"""` 不成對時回 `nil`。
    static func importedModules(inSource source: String) -> [String]? {
        var modules: [String] = []
        var isInsideMultilineString = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let delimiterCount = line.components(separatedBy: "\"\"\"").count - 1
            if !isInsideMultilineString, delimiterCount == 0, let module = importedModule(in: String(line)) {
                modules.append(module)
            }
            if delimiterCount % 2 == 1 { isInsideMultilineString.toggle() }
        }
        return isInsideMultilineString ? nil : modules
    }

    /// `import X`、`@preconcurrency import X`、`import struct X.Y` 都取出頂層 module 名稱 `X`。
    static func importedModule(in line: String) -> String? {
        var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, first.hasPrefix("@") { words.removeFirst() }
        guard words.first == "import", words.count >= 2 else { return nil }
        let kinds: Set<String> = ["struct", "class", "enum", "protocol", "typealias", "func", "var", "let"]
        let path = kinds.contains(words[1]) && words.count >= 3 ? words[2] : words[1]
        return path.split(separator: ".").first.map(String.init)
    }
}
