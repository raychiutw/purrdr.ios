import Foundation

extension AgentRow.Time {
    /// 右欄文字(行為規格 F2.4):工作中「現在」;今天 → 依地區的時:分;前一個曆日 → 「昨天」;
    /// 7 天內 → 星期縮寫;更早 → 月/日。
    public func text(now: Date = .now, calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        guard case .date(let date) = self else { return String(localized: "Now") }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0:
            style = style.hour().minute()
        case 1:
            return String(localized: "Yesterday")
        case 2..<7:
            style = style.weekday(.abbreviated)
        default:
            style = style.month(.twoDigits).day(.twoDigits)
        }
        return date.formatted(style)
    }
}
