import Foundation
import Observation
import PurrdrCore

/// 「通知」頁的今日推播用量(#677):進頁面讀一次、下拉重新整理再讀;不輪詢。
/// 讀不到時保留上次的值、沒有就維持 `nil`,畫面不顯示這一列也不報錯。
@MainActor
@Observable
public final class PushUsageModel {
    public private(set) var usage: PushDailyUsage?

    private let service: PushService

    public init(service: PushService) {
        self.service = service
    }

    public func load() async {
        guard let usage = try? await service.session.pushUsage() else { return }
        self.usage = usage
    }
}

/// 今日用量的顯示文字。時區與語系可注入(測試固定;畫面用手機目前的)。
public struct PushUsageText: Equatable, Sendable {
    public var usage: PushDailyUsage
    public var timeZone: TimeZone
    public var locale: Locale

    public init(_ usage: PushDailyUsage, timeZone: TimeZone = .current, locale: Locale = .current) {
        self.usage = usage
        self.timeZone = timeZone
        self.locale = locale
    }

    /// 「今日 23／100 則」;到達上限時「今日已達上限」。
    public var summary: String {
        if usage.isLimitReached { return String(localized: "Today’s limit reached") }
        return String(localized: "Today \(usage.sent) of \(usage.limit)")
    }

    /// 「8:00 歸零」(手機時區;後台以 UTC 0:00 歸零)。
    public var resetNote: String {
        String(localized: "Resets at \(resetTime)")
    }

    /// 歸零的時刻(只有時間,例如台灣 UTC 0:00 是早上 8:00)。
    public var resetTime: String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        style.calendar = locale.calendar
        return usage.resetsAt.formatted(style)
    }
}
