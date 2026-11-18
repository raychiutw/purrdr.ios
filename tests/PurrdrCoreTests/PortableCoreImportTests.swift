import Foundation
import Testing

/// 可攜核心(PurrdrCore、PurrdrSSH、PurrdrHTTPS、PurrdrDemo,ADR-0006)只能 import Foundation 與 swift-nio／swift-nio-ssh／swift-crypto 系列。
///
/// 真正的守門是 CI 用 Swift SDK for Android 編譯可攜核心;這個測試讓本機的 `swift test` 先擋一次,
/// 不必等 CI 才發現有人在核心 import 了 SwiftUI、Security 或 os。
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
                let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                for line in lines {
                    guard let module = Self.importedModule(in: String(line)), !Self.allowedModules.contains(module) else { continue }
                    violations.append("\(target)/\(file.lastPathComponent): import \(module)")
                }
            }
        }
        #expect(scanned > 0, "沒有掃到任何原始碼，路徑可能錯了")
        #expect(violations.isEmpty, "可攜核心 import 了不可攜的 module:\(violations)")
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
