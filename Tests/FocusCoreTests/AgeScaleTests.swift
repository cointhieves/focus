import Foundation
import Testing
@testable import FocusCore

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.locale = Locale(identifier: "en_US")
    return c
}()

private func utc(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    return f.date(from: s)!
}

// 2026-09-25 is a Friday, 2026-09-28 a Monday.
@Test func weekendIsSkipped() {
    #expect(WeekdayClock.hours(from: utc("2026-09-25T12:00:00Z"), to: utc("2026-09-28T12:00:00Z"), calendar: cal) == 24)
}

@Test func sameWeekday() {
    #expect(WeekdayClock.hours(from: utc("2026-09-28T09:00:00Z"), to: utc("2026-09-28T17:00:00Z"), calendar: cal) == 8)
}

@Test func weekendOnlyIsZero() {
    #expect(WeekdayClock.hours(from: utc("2026-09-26T08:00:00Z"), to: utc("2026-09-27T20:00:00Z"), calendar: cal) == 0)
}

@Test func bands() {
    let now = utc("2026-09-30T12:00:00Z")   // Wednesday
    let scale = AgeScale()
    let never = Item(id: 1, source: .jira, title: "t", detail: "d")
    #expect(scale.band(for: never, now: now, calendar: cal) == .red)

    let fresh = Item(id: 1, source: .jira, title: "t", detail: "d", lastMyResponse: utc("2026-09-30T02:00:00Z"))
    #expect(scale.band(for: fresh, now: now, calendar: cal) == .green)

    let mid = Item(id: 1, source: .jira, title: "t", detail: "d", lastMyResponse: utc("2026-09-29T06:00:00Z"))
    // Tue 9-17 (8h) + Wed 9-12 (3h) = 11 business hours: 3/8 of the way from green (8) to red (16).
    #expect(scale.band(for: mid, now: now, calendar: cal) == .ramp(0.375))

    let idea = Item(id: 1, source: .idea, title: "t", detail: "d")
    #expect(scale.band(for: idea, now: now, calendar: cal) == .none)
}
