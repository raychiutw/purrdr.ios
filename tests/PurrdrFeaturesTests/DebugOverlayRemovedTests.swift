import Foundation
import Testing

/// 聊天畫面不疊除錯浮層(使用者 2026-11-27 決定移除 #484 的順暢度除錯層):守門原始碼,擋它長回來。
@Suite("沒有除錯浮層")
struct DebugOverlayRemovedTests {
    static let sourceFolder = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "src")

    static var sourceFiles: [(name: String, text: String)] {
        let enumerator = FileManager.default.enumerator(at: sourceFolder, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) } }
    }

    @Test("原始碼沒有順暢度除錯層與它的隱藏旗標")
    func noScrollSmoothnessOverlay() {
        let files = Self.sourceFiles
        #expect(files.count > 50, "找不到 src 的原始碼")
        for (name, text) in files {
            for pattern in ["ScrollSmoothness", "hidesDebugOverlay", "疑似黑框"] {
                #expect(!text.contains(pattern), "\(name) 還有除錯浮層的程式(\(pattern))")
            }
        }
    }
}
