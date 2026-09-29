import Foundation

/// Counts elapsed hours, skipping weekend days. Holidays are deliberately not tracked.
public enum WeekdayClock {
    public static func hours(from start: Date, to end: Date, calendar: Calendar = .current) -> Double {
        guard end > start else { return 0 }
        var total: TimeInterval = 0
        var cursor = start
        // Walk day by day, adding only the portion of each weekday inside the range.
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let segmentEnd = min(nextDay, end)
            if !calendar.isDateInWeekend(cursor) {
                total += segmentEnd.timeIntervalSince(cursor)
            }
            cursor = segmentEnd
        }
        return total / 3600
    }

    /// The date that lies `hours` weekday hours before `end`. Used to build sample data.
    public static func date(weekdayHours hours: Double, before end: Date, calendar: Calendar = .current) -> Date {
        let step: TimeInterval = 900
        var remaining = hours * 3600
        var cursor = end
        while remaining > 0 {
            cursor -= step
            if !calendar.isDateInWeekend(cursor) { remaining -= step }
        }
        return cursor
    }
}

/// Counts elapsed hours inside working hours only: Monday to Friday, between
/// `startHour` and `endHour` local time. Used for Slack, which expects quick replies.
public enum BusinessClock {
    public static func hours(from start: Date, to end: Date, startHour: Double = 9, endHour: Double = 17,
                             calendar: Calendar = .current) -> Double {
        guard end > start, endHour > startHour else { return 0 }
        var total: TimeInterval = 0
        var day = calendar.startOfDay(for: start)
        while day < end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            if !calendar.isDateInWeekend(day) {
                let open = day.addingTimeInterval(startHour * 3600), close = day.addingTimeInterval(endHour * 3600)
                let from = max(start, open), to = min(end, close)
                if to > from { total += to.timeIntervalSince(from) }
            }
            day = next
        }
        return total / 3600
    }

    /// The date `hours` business hours after `start` (for the boomerang).
    public static func date(businessHours hours: Double, after start: Date, startHour: Double = 9, endHour: Double = 17,
                            calendar: Calendar = .current) -> Date {
        let step: TimeInterval = 60
        var remaining = hours * 3600, cursor = start, steps = 0
        while remaining > 0 && steps < 60 * 24 * 30 {
            // Count only the part of this minute inside business hours, so the result is exact.
            let inside = Self.hours(from: cursor, to: cursor + step, startHour: startHour, endHour: endHour, calendar: calendar) * 3600
            if inside >= remaining {
                // Land exactly: if the minute starts outside hours, business time begins at its end.
                return cursor + step - inside + remaining
            }
            remaining -= inside
            cursor += step
            steps += 1
        }
        return cursor
    }

    /// The date `hours` business hours before `end`. Used to build demo items.
    public static func date(businessHours hours: Double, before end: Date, startHour: Double = 9, endHour: Double = 17,
                            calendar: Calendar = .current) -> Date {
        let step: TimeInterval = 60
        var remaining = hours * 3600, cursor = end
        var guardSteps = 0
        while remaining > 0 && guardSteps < 60 * 24 * 60 {
            cursor -= step
            guardSteps += 1
            if Self.hours(from: cursor, to: cursor + step, startHour: startHour, endHour: endHour, calendar: calendar) > 0 {
                remaining -= step
            }
        }
        return cursor
    }
}

/// Maps an item's age to a color band: green until the target, a ramp, then red.
public struct AgeScale: Sendable {
    public var greenUntilHours: Double
    public var redAtHours: Double
    /// Slack ages much faster, in business hours.
    public var slackGreenHours: Double
    public var slackRedHours: Double
    public var workStartHour: Double
    public var workEndHour: Double

    public init(greenUntilHours: Double = 8, redAtHours: Double = 16,
                slackGreenHours: Double = 1, slackRedHours: Double = 2,
                workStartHour: Double = 9, workEndHour: Double = 17) {
        self.greenUntilHours = greenUntilHours
        self.redAtHours = redAtHours
        self.slackGreenHours = slackGreenHours
        self.slackRedHours = slackRedHours
        self.workStartHour = workStartHour
        self.workEndHour = workEndHour
    }

    public enum Band: Equatable, Sendable {
        case none           // ideas: no aging
        case green
        case ramp(Double)   // 0...1 between green and red
        case red
        case due(Double)    // timed item: 0 = plenty of time (blue) ... 1 = due now (red)
    }

    /// Business hours since my last Jira comment, or since the first Slack message I
    /// haven't answered. One clock for everything.
    public func hours(for item: Item, now: Date, calendar: Calendar = .current) -> Double? {
        if item.source == .slack || item.waitingSince != nil {
            guard let since = item.waitingSince else { return nil }
            return BusinessClock.hours(from: since, to: now, startHour: workStartHour, endHour: workEndHour, calendar: calendar)
        }
        guard let last = item.lastMyResponse else { return nil }
        return BusinessClock.hours(from: last, to: now, startHour: workStartHour, endHour: workEndHour, calendar: calendar)
    }

    public func band(for item: Item, now: Date, calendar: Calendar = .current) -> Band {
        switch item.source {
        case .idea:
            guard let due = item.dueAt else { return .none }
            if now >= due { return .red }
            // Blue for the first two thirds of the window, then ramp to red.
            let left = Deadline.remainingFraction(created: item.createdAt, due: due, now: now)
            return .due(left >= 1.0 / 3 ? 0 : 1 - left * 3)
        case .slack, .jira: break
        }
        guard let h = hours(for: item, now: now, calendar: calendar) else { return .red }
        let (green, red) = item.source == .slack ? (slackGreenHours, slackRedHours) : (greenUntilHours, redAtHours)
        if h < green { return .green }
        if h >= red { return .red }
        return .ramp((h - green) / (red - green))
    }
}
