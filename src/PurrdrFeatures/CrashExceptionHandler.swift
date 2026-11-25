import Foundation
import PurrdrAgentFeatures

/// 安裝 Objective-C 未捕捉例外處理器:中止前交給 `CrashReporter` 寫標記,再轉呼叫原本的處理器。
/// 處理器是 C 函式指標、不能捕捉變數,所以用全域狀態(只在啟動時設定一次)。
public enum CrashExceptionHandler {
    nonisolated(unsafe) private static var reporter: CrashReporter?
    nonisolated(unsafe) private static var previous: (@convention(c) (NSException) -> Void)?

    public static func install(_ reporter: CrashReporter) {
        guard Self.reporter == nil else { return }
        Self.reporter = reporter
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashExceptionHandler.reporter?.exceptionWillTerminate(name: exception.name.rawValue, reason: exception.reason)
            CrashExceptionHandler.previous?(exception)
        }
    }
}
