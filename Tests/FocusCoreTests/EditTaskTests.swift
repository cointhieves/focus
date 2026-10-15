import Foundation
import Testing
@testable import FocusCore

private func store() throws -> Store {
    try Store(path: FileManager.default.temporaryDirectory.appendingPathComponent("focus-e-\(UUID().uuidString)/focus.db").path)
}
private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Test func editChangesTextAndKeepsPlace() throws {
    let s = try store()
    let a = try s.addIdea("first", now: t0)
    _ = try s.addIdea("second", now: t0.addingTimeInterval(1))
    let e = try s.editIdea(a.id, text: "first, reworded", now: t0.addingTimeInterval(5))
    #expect(e.title == "first, reworded" && e.dueAt == nil)
    #expect(try s.queue().map(\.title) == ["first, reworded", "second"])   // same place
}

@Test func editSetsChangesAndRemovesTheTime() throws {
    let s = try store()
    let a = try s.addIdea("call Sam", now: t0)
    let set = try s.editIdea(a.id, text: "call Sam in 2 hours", now: t0.addingTimeInterval(60))
    #expect(set.title == "call Sam")
    #expect(set.dueAt == t0.addingTimeInterval(60 + 7200))
    #expect(set.dueSetAt == t0.addingTimeInterval(60))
    let moved = try s.editIdea(a.id, text: "call Sam in 30 minutes", now: t0.addingTimeInterval(120))
    #expect(moved.dueAt == t0.addingTimeInterval(120 + 1800) && moved.warnedLevel == 0)
    let cleared = try s.editIdea(a.id, text: "call Sam", now: t0.addingTimeInterval(180))
    #expect(cleared.dueAt == nil)
}

@Test func editRefusesEmptyPastAndNonTasks() throws {
    let s = try store()
    let a = try s.addIdea("x", now: t0)
    #expect(throws: StoreError.self) { try s.editIdea(a.id, text: "   ", now: t0) }
    #expect(try s.item(a.id).title == "x")   // unchanged after a refused edit
    let j = JiraTicketState(key: "ABC-1", summary: "s", myLastComment: nil, waitingOnMe: false, changeMarker: "none")
    try s.applyJira([j], inScopeKeys: ["ABC-1"], site: nil)
    let jid = try s.queue().first { $0.source == .jira }!.id
    #expect(throws: StoreError.self) { try s.editIdea(jid, text: "new", now: t0) }
}

// Warnings measure from when the time was set, not when the task was added: a week-old task
// edited to "in 2 hours" isn't instantly at its last warning.
@Test func warningsMeasureFromTheEdit() throws {
    let s = try store()
    let a = try s.addIdea("report", now: t0)
    let edit = t0.addingTimeInterval(7 * 86_400)
    _ = try s.editIdea(a.id, text: "report in 2 hours", now: edit)
    #expect(try s.advanceDeadlines(now: edit.addingTimeInterval(60)).isEmpty)
    #expect(try s.advanceDeadlines(now: edit.addingTimeInterval(7200 * 0.95)) == [a.id])   // 5% left
}

@Test func textOnlyEditKeepsTheDeadlineAndWarnings() throws {
    // The system date reader resolves "by <time>" against the real clock, so use today.
    let start = Date().addingTimeInterval(17)
    let s = try store()
    let a = try s.addIdea("deploy in 2 hours", now: start)     // due has seconds
    let due = try #require(try s.item(a.id).dueAt)
    // The editor writes the time back to the minute; the parse lands within a minute of it.
    let f = DateFormatter(); f.dateFormat = "EEEE MMM d h:mma"
    let e = try s.editIdea(a.id, text: "deploy to prod by \(f.string(from: due).lowercased())",
                           now: start.addingTimeInterval(60))
    #expect(e.title == "deploy to prod")
    #expect(e.dueAt == due)
    #expect(e.dueSetAt == nil)
}
