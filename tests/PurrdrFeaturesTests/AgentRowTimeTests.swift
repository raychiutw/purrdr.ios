import Foundation
import PurrdrFeatures
import Testing

/// 列右欄的時間文字(行為規格 F2.4)。
@Suite("Agent 列的時間")
struct AgentRowTimeTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let locale = Locale(identifier: "en_GB")
    /// 2026-11-15(星期日)15:00 UTC。
    static let now = Date(timeIntervalSince1970: 1_794_754_800)

    static func text(_ time: AgentRow.Time) -> String {
        time.text(now: now, calendar: calendar, locale: locale)
    }

    static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test("工作中顯示「現在」")
    func workingShowsNow() {
        #expect(Self.text(.now) == "Now")
    }

    @Test("今天：依裝置地區的時:分")
    func todayShowsTime() {
        #expect(Self.text(.date(Self.date(15, 9, 5))) == "09:05")
    }

    @Test("前一個曆日：「昨天」,即使才過幾分鐘")
    func previousCalendarDayShowsYesterday() {
        #expect(Self.text(.date(Self.date(14, 23, 59))) == "Yesterday")
    }

    @Test("7 天內：星期縮寫")
    func withinAWeekShowsWeekday() {
        #expect(Self.text(.date(Self.date(10, 8, 0))) == "Tue")
    }

    @Test("更早：月/日")
    func olderShowsMonthAndDay() {
        #expect(Self.text(.date(Self.date(1, 8, 0))) == "01/11")
    }
}
