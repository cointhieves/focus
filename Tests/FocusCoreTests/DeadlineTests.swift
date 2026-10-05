import Foundation
import Testing
@testable import FocusCore

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .current
    return c
}()

/// Today at the given local hour/minute.
private func today(_ h: Int, _ m: Int = 0) -> Date {
    cal.date(bySettingHour: h, minute: m, second: 0, of: Date())!
}

@Test func parsesByTime() {
    let now = today(13, 0)
    let r = Deadline.parse("take out the trash by 5pm", now: now, calendar: cal)
    #expect(r.title == "take out the trash")
    #expect(r.due == today(17, 0))
}

@Test func pastTimeRollsToTomorrow() {
    let now = today(13, 0)
    let r = Deadline.parse("water plants by 11am", now: now, calendar: cal)
    #expect(r.due == cal.date(byAdding: .day, value: 1, to: today(11, 0)))
}

@Test func parsesNoonAndRelative() {
    let now = today(9, 0)
    #expect(Deadline.parse("lunch order by noon", now: now, calendar: cal).due == today(12, 0))
    let rel = Deadline.parse("stretch in 30 minutes", now: now, calendar: cal)
    #expect(rel.title == "stretch")
    #expect(rel.due == now.addingTimeInterval(1800))
    #expect(Deadline.parse("deploy in 2 hours", now: now, calendar: cal).due == now.addingTimeInterval(7200))
}

@Test func dateWithoutByIsNotADeadline() {
    let r = Deadline.parse("meeting notes from Monday", now: today(9), calendar: cal)
    #expect(r.due == nil)
    #expect(r.title == "meeting notes from Monday")
}

@Test func warningLevels() {
    let created = today(8, 0)
    let due = today(18, 0)   // 10h window: 10% = 1h, 5% = 30m
    #expect(Deadline.level(created: created, due: due, now: today(16, 0)) == 0)
    #expect(Deadline.level(created: created, due: due, now: today(17, 0)) == 1)
    #expect(Deadline.level(created: created, due: due, now: today(17, 30)) == 2)
    #expect(Deadline.level(created: created, due: due, now: today(18, 0)) == 3)
}

@Test func shortWindowUsesPercentagesOnly() {
    let created = today(12, 0)
    let due = today(12, 20)   // 20m window: 10% = 2m, 5% = 1m
    #expect(Deadline.level(created: created, due: due, now: today(12, 17)) == 0)
    #expect(Deadline.level(created: created, due: due, now: today(12, 18)) == 1)
    #expect(Deadline.level(created: created, due: due, now: today(12, 19)) == 2)
    #expect(Deadline.level(created: created, due: due, now: today(12, 20)) == 3)
}

@Test func colorStaysBlueThenRamps() {
    let scale = AgeScale()
    var item = Item(id: 1, source: .idea, title: "t", detail: "", createdAt: today(9, 0))
    item.dueAt = today(12, 0)   // 3h window; final third starts at 11:00
    #expect(scale.band(for: item, now: today(10, 30)) == .due(0))
    #expect(scale.band(for: item, now: today(11, 30)) == .due(0.5))
    #expect(scale.band(for: item, now: today(12, 1)) == .red)
}

@Test func warningPopsToFrontOncePerLevel() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("focus-test-\(UUID().uuidString)/focus.db").path
    let s = try Store(path: path)
    let created = today(8, 0)
    try s.addIdea("older idea", now: created.addingTimeInterval(-60))
    let timed = try s.addIdea("trash", due: today(18, 0), now: created)
    try s.skip(timed.id)   // buried at the back, under "+N more"
    #expect(try s.queue().first?.title == "older idea")

    #expect(try s.advanceDeadlines(now: today(16, 0)).isEmpty)
    #expect(try s.advanceDeadlines(now: today(17, 0)) == [timed.id])
    #expect(try s.queue().first?.id == timed.id)
    // Same level again: nothing new.
    #expect(try s.advanceDeadlines(now: today(17, 10)).isEmpty)
    // Final warning fires even though it is already first (so it shakes again).
    let before = try s.item(timed.id).movedAt
    #expect(try s.advanceDeadlines(now: today(17, 35)) == [timed.id])
    #expect(try s.item(timed.id).movedAt > before)
    // Going overdue alerts once more.
    #expect(try s.advanceDeadlines(now: today(18, 0)) == [timed.id])
    #expect(try s.advanceDeadlines(now: today(18, 30)).isEmpty)
}

@Test func addIdeaParsesDeadlineFromText() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("focus-test-\(UUID().uuidString)/focus.db").path
    let s = try Store(path: path)
    let item = try s.addIdea("take out the trash in 45 minutes", now: today(9, 0))
    #expect(item.title == "take out the trash")
    #expect(item.dueAt == today(9, 45))
}

@Test func trailingDayAndTimeWithoutBy() {
    let now = today(10, 0)
    let r = Deadline.parse("check in with Ann on the edge rollout tomorrow at 10am", now: now, calendar: cal)
    #expect(r.title == "check in with Ann on the edge rollout")
    #expect(r.due == cal.date(byAdding: .day, value: 1, to: today(10, 0)))
}

@Test func trailingDayWithoutTimeIsEndOfWorkday() {
    let now = today(10, 0)
    let r = Deadline.parse("check in with Bob about n8n on wednesday", now: now, endOfDayHour: 17, calendar: cal)
    #expect(r.title == "check in with Bob about n8n")
    let due = try! #require(r.due)
    #expect(cal.component(.weekday, from: due) == 4)           // Wednesday
    #expect(cal.component(.hour, from: due) == 17 && cal.component(.minute, from: due) == 0)
    #expect(due > now)
    // A custom end of day, and "by <day>" uses the same rule.
    let byDay = Deadline.parse("send report by friday", now: now, endOfDayHour: 16.5, calendar: cal).due!
    #expect(cal.component(.hour, from: byDay) == 16 && cal.component(.minute, from: byDay) == 30)
}

@Test func dateInMiddleOrAfterFromIsNotADeadline() {
    #expect(Deadline.parse("notes on Monday's outage review", now: today(9), calendar: cal).due == nil)
    #expect(Deadline.parse("follow up since tuesday", now: today(9), calendar: cal).due == nil)
}
