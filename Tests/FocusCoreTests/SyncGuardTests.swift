import Foundation
import Testing
@testable import FocusCore

private func row(_ ext: String, removed: Bool = false) -> Item {
    Item(id: Int64(abs(ext.hashValue % 10_000)), source: .jira, externalId: ext, title: ext, detail: ext,
         createdAt: Date(), movedAt: Date(), removedAt: removed ? Date() : nil)
}

// One empty Jira answer must not wipe the panel; a second in a row is believed.
@Test func emptySprintIsHeldOnceThenBelieved() {
    let showing = [row("ABC-1")]
    let first = SyncGuards.holdEmptySprint(scopeIsEmpty: true, items: showing, emptyBefore: 0)
    #expect(first.hold && first.empty == 1)
    let second = SyncGuards.holdEmptySprint(scopeIsEmpty: true, items: showing, emptyBefore: first.empty)
    #expect(!second.hold && second.empty == 0)
    // Nothing to protect (only mentions / removed rows showing): no hold.
    #expect(!SyncGuards.holdEmptySprint(scopeIsEmpty: true, items: [row("mention:ABC-2"), row("ABC-3", removed: true)],
                                        emptyBefore: 0).hold)
    // A normal non-empty result resets the counter.
    #expect(SyncGuards.holdEmptySprint(scopeIsEmpty: false, items: showing, emptyBefore: 1) == (false, 0))
}

// Removing someone from "Ignore comments from" removes their saved name too.
@Test func removingAnIgnoredPersonDropsTheirName() {
    let names = ["id-1": "Ann", "id-2": "Bob"]
    #expect(SyncGuards.prunedNames(names, keeping: ["id-2"]) == ["id-2": "Bob"])
    #expect(SyncGuards.prunedNames(names, keeping: []) == [:])
}

// A hidden panel: things that need you show and stay; a farewell shows, then hides again
// (default); "never" keeps it hidden; "stay" is the old show-and-stay for everything.
@Test func hiddenPanelActionFollowsTheSetting() {
    #expect(SyncGuards.hiddenPanelAction(needsYou: true, setting: .farewellsHide) == .showAndStay)
    #expect(SyncGuards.hiddenPanelAction(needsYou: false, setting: .farewellsHide) == .showThenHide)
    #expect(SyncGuards.hiddenPanelAction(needsYou: false, setting: .stay) == .showAndStay)
    #expect(SyncGuards.hiddenPanelAction(needsYou: true, setting: .never) == .stayHidden)
    #expect(FocusSettings().whileHidden == .farewellsHide)
}
