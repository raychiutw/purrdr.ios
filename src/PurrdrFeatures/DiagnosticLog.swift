import Foundation
import os

/// 不給使用者看、只留給開發者的紀錄(Console.app、sysdiagnose):背景動作失敗了，但畫面不必因此出錯的情況。
/// 以 initializer 注入，測試用記錄訊息的假實作。
public struct DiagnosticLog: Sendable {
    private let record: @MainActor @Sendable (String) -> Void

    public init(_ record: @escaping @MainActor @Sendable (String) -> Void) {
        self.record = record
    }

    @MainActor
    func error(_ message: String) {
        record(message)
    }

    /// 一般層級的系統紀錄(不是錯誤，例如對話紀錄追蹤退回輪詢的原因)。
    public static func systemNotice(category: String) -> @Sendable (String) -> Void {
        let logger = Logger(subsystem: "com.raychiu.purrdr", category: category)
        return { message in logger.notice("\(message, privacy: .public)") }
    }

    /// 系統紀錄(`os.Logger`,subsystem 是 bundle id)。
    public static func system(category: String) -> DiagnosticLog {
        let logger = Logger(subsystem: "com.raychiu.purrdr", category: category)
        return DiagnosticLog { message in logger.error("\(message, privacy: .public)") }
    }
}
