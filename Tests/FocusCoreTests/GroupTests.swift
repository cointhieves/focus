import Foundation
import Testing
@testable import FocusCore

private func store() throws -> Store {
    try Store(path: FileManager.default.temporaryDirectory.appendingPathComponent("focus-g-\(UUID().uuidString)/focus.db").path)
}
private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func titles(_ s: Store) throws -> [String] { try s.queue().map { ($0.isGroup ? "#" : "") + $0.title } }

// Make this a group creates an EMPTY group: it no longer sweeps in the tasks below it.
@Test func makeGroupStartsEmpty() throws {
    let s = try store()
    let h = try s.addIdea("PROJECT X", now: t0)
    _ = try s.addIdea("unrelated task", now: t0.addingTimeInterval(1))
    try s.makeGroup(h.id)
    #expect(try s.queue().allSatisfy { $0.groupId == nil })
}

private func grouped(_ s: Store, _ h: Item, _ names: [String], at t: Date = t0) throws -> [Item] {
    try names.enumerated().map { n, name in
        try s.addIdea(name, toGroup: h.id, now: t.addingTimeInterval(Double(n + 1)))
    }
}

@Test func addMoveAndRemoveTasks() throws {
    let s = try store()
    let loose = try s.addIdea("loose", now: t0)
    let a = try s.addGroup("A", now: t0.addingTimeInterval(1))     // new groups go to the end
    let b = try s.addGroup("B", now: t0.addingTimeInterval(2))
    let tasks = try grouped(s, a, ["a1", "a2"], at: t0.addingTimeInterval(3))
    #expect(try titles(s) == ["loose", "#A", "a1", "a2", "#B"])
    try s.moveTask(loose.id, toGroup: b.id)                                // drag in
    try s.moveTask(tasks[1].id, toGroup: a.id, before: tasks[0].id)        // reorder within
    #expect(try titles(s) == ["#A", "a2", "a1", "#B", "loose"])
    try s.moveTask(tasks[0].id, toGroup: b.id, before: loose.id)           // between groups
    #expect(try titles(s) == ["#A", "a2", "#B", "a1", "loose"])
    try s.moveTask(tasks[1].id, toGroup: nil)                              // out, to the end
    #expect(try titles(s) == ["#A", "#B", "a1", "loose", "a2"])
}

@Test func addGroupAboveOrBelowAndRename() throws {
    let s = try store()
    let x = try s.addIdea("x", now: t0)
    let y = try s.addIdea("y", now: t0.addingTimeInterval(1))
    let g1 = try s.addGroup("ABOVE Y", near: y.id, above: true, now: t0.addingTimeInterval(2))
    _ = try s.addGroup("BELOW X", near: x.id, above: false, now: t0.addingTimeInterval(3))
    #expect(try titles(s) == ["x", "#BELOW X", "#ABOVE Y", "y"])
    try s.renameGroup(g1.id, to: "  renamed  ")
    #expect(try titles(s).contains("#renamed"))
    #expect(throws: StoreError.self) { try s.renameGroup(x.id, to: "nope") }
}

@Test func jiraRowsCantJoinGroups() throws {
    let s = try store()
    let g = try s.addGroup("G", now: t0)
    let j = JiraTicketState(key: "ABC-1", summary: "s", myLastComment: nil, waitingOnMe: false, changeMarker: "none")
    try s.applyJira([j], inScopeKeys: ["ABC-1"], site: nil)
    let jid = try s.queue().first { $0.source == .jira }!.id
    #expect(throws: StoreError.self) { try s.moveTask(jid, toGroup: g.id) }
}

// Inside a group: timed tasks soonest first, then untimed in their order.
@Test func timedTasksSortSoonestFirstInsideAGroup() throws {
    let s = try store()
    let now = Date()
    let h = try s.addGroup("HEAD", now: now)
    _ = try grouped(s, h, ["untimed one", "later in 5 hours", "sooner in 1 hour"], at: now)
    #expect(try titles(s) == ["#HEAD", "sooner", "later", "untimed one"])
}

// A fired warning: the task goes to the top of its group and the group to the top of the
// panel; dealing with it (Skip) puts the group back.
@Test func firedWarningMovesTheGroupToTheTop() throws {
    let s = try store()
    let now = Date()
    _ = try s.addIdea("loose task", now: now)
    let h = try s.addGroup("HEAD", now: now.addingTimeInterval(1))
    let timed = try grouped(s, h, ["plain", "deploy in 10 minutes"], at: now.addingTimeInterval(1))[1]
    #expect(try titles(s) == ["loose task", "#HEAD", "deploy", "plain"])
    _ = try s.advanceDeadlines(now: now.addingTimeInterval(9.6 * 60))   // 5% left: fires
    #expect(try titles(s) == ["#HEAD", "deploy", "plain", "loose task"])
    try s.skip(timed.id)                                                   // dealt with
    #expect(try titles(s) == ["loose task", "#HEAD", "deploy", "plain"])
}

@Test func skipInsideAGroupGoesToTheBottomOfTheGroup() throws {
    let s = try store()
    let h = try s.addGroup("HEAD", now: t0)
    _ = try s.addGroup("OTHER", now: t0.addingTimeInterval(0.5))
    let a = try grouped(s, h, ["a", "b", "after"])[0]
    try s.skip(a.id)
    #expect(try titles(s) == ["#HEAD", "b", "after", "a", "#OTHER"])
}

@Test func ungroupAndDeletingAHeadingReleaseTheTasks() throws {
    let s = try store()
    let h = try s.addGroup("HEAD", now: t0)
    _ = try grouped(s, h, ["a"])
    try s.ungroup(h.id)
    #expect(try s.queue().allSatisfy { !$0.isGroup && $0.groupId == nil })
    try s.makeGroup(h.id)
    _ = try s.moveTask(try s.queue().first { $0.title == "a" }!.id, toGroup: h.id)
    try s.deleteIdea(h.id)
    #expect(try titles(s) == ["a"])
    #expect(try s.queue().first?.groupId == nil)
}

@Test func headingsCantBeEditedAndMembersCantBecomeGroups() throws {
    let s = try store()
    let h = try s.addGroup("HEAD", now: t0)
    let a = try grouped(s, h, ["a"])[0]
    #expect(throws: StoreError.self) { try s.editIdea(h.id, text: "x", now: t0) }
    #expect(throws: StoreError.self) { try s.makeGroup(a.id) }
}
