import Foundation
import Testing

/// 停用的填色主要按鈕(#726):深色模式下強制的字色與填色不會跟著停用變淡,會變成看不見的一塊黑。
/// 原始碼守門,prior art:`ProminentFillUsageTests`。
@Suite("停用的填色主要按鈕")
struct DisabledProminentButtonTests {
    private static func source(_ name: String) throws -> String {
        let folder = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/PurrdrFeatures")
        return try String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    @Test("填色主要按鈕的樣式停用時不套強制字色與填色(交給系統停用外觀)")
    func modifierFallsBackToSystemWhenDisabled() throws {
        let style = try Self.source("FilledProminentButtonStyle.swift")
        #expect(style.contains("@Environment(\\.isEnabled)"), "FilledProminentModifier 要讀 isEnabled,停用時不套 .foregroundStyle(.onProminentFill)")
        #expect(style.contains("if !isEnabled"))
    }

    @Test("新增主機引導連線中的底部面板不放停用的主要按鈕")
    func connectingPanelHasNoDisabledPrimary() throws {
        let guide = try Self.source("AddHostGuideView.swift")
        #expect(!guide.contains("enabled: false"), "連線中不要放停用的主要按鈕(空的長條);只放可以按的取消")
        #expect(!guide.contains("guide.connecting\""), "guide.connecting 停用按鈕已拿掉")
        #expect(guide.contains("guide.connectingCancel"))
    }
}
