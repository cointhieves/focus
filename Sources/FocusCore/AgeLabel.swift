import Foundation

/// The short "when" text shown for an item, shared by the panel and the CLI.
/// Colors are decided elsewhere (AgeScale); this only describes the time.
public enum AgeLabel {
    /// "10:25 AM" today, "Thu 10:25 AM" within the last week, "Sep 18 10:25 AM" older.
    public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            f.setLocalizedDateFormatFromTemplate("jmm")
        } else if now.timeIntervalSince(date) < 6 * 86_400 {
            f.setLocalizedDateFormatFromTemplate("EEEjmm")
        } else {
            f.setLocalizedDateFormatFromTemplate("MMMdjmm")
        }
        // Some locales join date and time with " at "; keep it compact.
        return f.string(from: date).replacingOccurrences(of: " at ", with: " ")
    }

    /// "14 business hrs ago" / "35 business min ago".
    public static func businessAgo(_ hours: Double) -> String {
        hours < 1 ? "\(Int(hours * 60)) business min ago" : "\(Int(hours)) business hr\(Int(hours) == 1 ? "" : "s") ago"
    }

    public static func text(for item: Item, scale: AgeScale, now: Date = Date(), calendar: Calendar = .current) -> String {
        if let until = item.snoozedUntil { return "back \(when(until, now: now, calendar: calendar))" }
        if let due = item.dueAt { return Deadline.countdown(to: due, now: now) }
        switch item.source {
        case .idea: return "task"
        case .slack:
            // When the first unanswered message arrived.
            guard let since = item.waitingSince else { return "new" }
            return stamp(since, scale: scale, now: now, calendar: calendar)
        case .jira:
            if item.removed { return "no longer in your sprint" }
            // A mention: when they asked.
            if let since = item.waitingSince { return stamp(since, scale: scale, now: now, calendar: calendar) }
            // When I last commented.
            guard let last = item.lastMyResponse else { return "never" }
            return stamp(last, scale: scale, now: now, calendar: calendar)
        }
    }

    /// "Thu 10:25 AM (14 business hrs ago)": same format for every source.
    static func stamp(_ date: Date, scale: AgeScale, now: Date, calendar: Calendar) -> String {
        let h = BusinessClock.hours(from: date, to: now, startHour: scale.workStartHour,
                                    endHour: scale.workEndHour, calendar: calendar)
        return "\(when(date, now: now, calendar: calendar)) (\(businessAgo(h)))"
    }
}
