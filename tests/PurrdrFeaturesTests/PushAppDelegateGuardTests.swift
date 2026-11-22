import Foundation
import Testing

/// 點推播通知閃退的守門(#327):通知 delegate 不能用 async 版的 `didReceive`／`willPresent`(它們的 completion 會在
/// cooperative 背景 thread 結束,UIKit 的 snapshot／state restoration 在 main-thread assertion 上 abort),
/// 要用 completion handler 版,並在 main actor 上才呼叫 `completionHandler`。
/// delegate 在 app target、`swift test` 沒辦法建立它,所以掃原始碼;thread 行為本身只能實機驗收。
@Suite("推播通知 delegate(#327 守門)")
struct PushAppDelegateGuardTests {
    static let source: String = {
        let file = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "src/App/Purrdr/PushAppDelegate.swift")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }()

    /// 去掉註解,只看程式碼。
    static var code: String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("didReceive／willPresent 用 completion handler 版,不是 async 版")
    func usesCompletionHandlerVersions() throws {
        try #require(!Self.source.isEmpty, "找不到 PushAppDelegate.swift")
        #expect(Self.code.contains("didReceive response: UNNotificationResponse,\n        withCompletionHandler"), "didReceive 要用 completion handler 版")
        #expect(Self.code.contains("willPresent notification: UNNotification,\n        withCompletionHandler"), "willPresent 要用 completion handler 版")
        let asyncVersion = /UNNotification(Response)?\)\s*(async|\n\s*async)/
        #expect(Self.code.firstMatch(of: asyncVersion) == nil, "不要用 async 版的通知 delegate 方法")
    }

    @Test("didReceive 在 main actor 上才呼叫 completionHandler")
    func completesOnMainActor() throws {
        try #require(!Self.source.isEmpty, "找不到 PushAppDelegate.swift")
        let body = try #require(Self.code.range(of: "didReceive response")).upperBound
        let rest = String(Self.code[body...])
        let task = try #require(rest.range(of: "Task { @MainActor in"), "didReceive 沒有切到 main actor")
        let completion = try #require(rest.range(of: "completionHandler()"), "didReceive 沒有呼叫 completionHandler")
        #expect(task.lowerBound < completion.lowerBound, "completionHandler 要在 Task { @MainActor in } 裡呼叫")
    }
}
