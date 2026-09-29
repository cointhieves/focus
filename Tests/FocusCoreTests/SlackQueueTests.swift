import Foundation
import Testing
@testable import FocusCore

private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

@Test func businessClockCountsOnlyWorkingHours() {
    // Friday 16:30 -> Monday 09:30 = 30 min Friday + 30 min Monday.
    #expect(BusinessClock.hours(from: at("2026-10-02T16:30:00Z"), to: at("2026-10-05T09:30:00Z"), calendar: utc) == 1)
    // A 9pm message: nothing counts until 9am.
    #expect(BusinessClock.hours(from: at("2026-09-30T21:00:00Z"), to: at("2026-10-01T08:59:00Z"), calendar: utc) == 0)
    #expect(BusinessClock.hours(from: at("2026-09-30T21:00:00Z"), to: at("2026-10-01T11:00:00Z"), calendar: utc) == 2)
    // Whole weekend: zero.
    #expect(BusinessClock.hours(from: at("2026-10-03T10:00:00Z"), to: at("2026-10-04T15:00:00Z"), calendar: utc) == 0)
    // Round trip for demos.
    let now = at("2026-09-30T14:00:00Z")
    let d = BusinessClock.date(businessHours: 1.5, before: now, calendar: utc)
    #expect(abs(BusinessClock.hours(from: d, to: now, calendar: utc) - 1.5) < 0.02)
}

@Test func slackAgesByBusinessHoursWithItsOwnThresholds() {
    let scale = AgeScale(slackGreenHours: 1, slackRedHours: 2)
    let now = at("2026-09-30T14:00:00Z")
    func item(_ since: String) -> Item { Item(id: 1, source: .slack, title: "", detail: "", waitingSince: at(since)) }
    #expect(scale.band(for: item("2026-09-30T13:30:00Z"), now: now, calendar: utc) == .green)
    #expect(scale.band(for: item("2026-09-30T12:30:00Z"), now: now, calendar: utc) == .ramp(0.5))
    #expect(scale.band(for: item("2026-09-30T11:00:00Z"), now: now, calendar: utc) == .red)
}

private func tempStore() throws -> Store {
    try Store(path: FileManager.default.temporaryDirectory.appendingPathComponent("focus-slack-\(UUID().uuidString)/focus.db").path)
}
private func st(_ key: String, marker: String, since: Date = Date(timeIntervalSince1970: 1_000)) -> SlackItemState {
    SlackItemState(key: key, title: "Ann: hi", detail: "DM", url: nil, waitingSince: since, marker: marker)
}
private let all = Set(SlackKind.all)

@Test func slackPopsOnceAndMoreMessagesDoNotRePop() throws {
    let s = try tempStore()
    try s.addIdea("older idea", now: Date(timeIntervalSince1970: 1))
    #expect(try s.applySlack([st("dm:C1", marker: "1")], answered: [], kinds: all) == ["dm:C1"])
    try s.skip(try #require(try s.queue().first { $0.externalId == "dm:C1" }?.id))   // push it back
    // More messages arrive: marker changes, no pop, clock start unchanged.
    #expect(try s.applySlack([st("dm:C1", marker: "2", since: Date(timeIntervalSince1970: 5_000))], answered: [], kinds: all).isEmpty)
    let row = try #require(try s.queue().first { $0.externalId == "dm:C1" })
    #expect(row.backSeq != nil)
    // The clock start follows the sync (a reaction can move it later).
    #expect(row.waitingSince == Date(timeIntervalSince1970: 5_000))
}

@Test func slackAnsweredIsDeletedAndLaterMessagePopsAgain() throws {
    let s = try tempStore()
    try s.applySlack([st("dm:C1", marker: "1")], answered: [], kinds: all)
    try s.applySlack([], answered: ["dm:C1"], kinds: all)
    #expect(try s.queue().isEmpty)
    try s.addIdea("something else", now: Date(timeIntervalSince1970: 1))   // so a pop is visible
    #expect(try s.applySlack([st("dm:C1", marker: "3", since: Date(timeIntervalSince1970: 9_000))], answered: [], kinds: all) == ["dm:C1"])
    #expect(try s.queue().first?.waitingSince == Date(timeIntervalSince1970: 9_000))
}

@Test func slackUnseenItemsStayAndKindsFilter() throws {
    let s = try tempStore()
    try s.applySlack([st("dm:C1", marker: "1"), st("thread:C2:9", marker: "1")], answered: [], kinds: all)
    try s.applySlack([], answered: [], kinds: all)
    #expect(try s.queue().count == 2)   // not answered: stays
    // Turning Threads off hides the thread (kept, not deleted); turning it back on restores it.
    try s.setPref("slack_kinds", "dm")
    #expect(try s.queue().map(\.externalId) == ["dm:C1"])
    try s.setPref("slack_kinds", "dm,thread")
    #expect(try s.queue().count == 2)
    // Slack off hides everything Slack; on again restores it.
    try s.setPref("slack_enabled", "0")
    #expect(try s.queue().isEmpty)
    try s.setPref("slack_enabled", "1")
    #expect(try s.queue().count == 2)
}

@Test func slackDismissedReturnsOnNewActivity() throws {
    let s = try tempStore()
    try s.applySlack([st("dm:C1", marker: "1")], answered: [], kinds: all)
    try s.dismiss(try #require(try s.queue().first?.id))
    #expect(try s.queue().isEmpty)
    #expect(try s.applySlack([st("dm:C1", marker: "1")], answered: [], kinds: all).isEmpty)
    #expect(try s.queue().isEmpty)
    try s.applySlack([st("dm:C1", marker: "2")], answered: [], kinds: all)
    #expect(try s.queue().count == 1)
}

@Test func slackMarkupIsCleaned() {
    let raw = "hey <@U1> see <#C9|ops> and <https://x.io/a|the doc> or <https://y.io> &amp; <!here>\n\nthanks <@U2|bob>"
    #expect(SlackSource.clean(raw, names: ["U1": "Sam"]) == "hey @Sam see #ops and the doc or https://y.io & @here thanks @bob")
    #expect(SlackSource.clean("", names: [:]) == "(attachment)")
    #expect(SlackSource.clean(String(repeating: "a", count: 200), names: [:], limit: 10) == "aaaaaaaaa…")
    #expect(SlackSource.mentionIds("<@U1> <@W22|x>") == ["U1", "W22"])
    #expect(SlackSource.threadParam("https://x.slack.com/archives/C1/p1?thread_ts=1.2&cid=C1") == "1.2")
    #expect(SlackSource.threadParam("https://x.slack.com/archives/C1/p1") == nil)
}

@Test func labelsShowArrivalAndBusinessHours() {
    var cal = utc; cal.locale = Locale(identifier: "en_US")
    let now = at("2026-09-27T15:00:00Z")   // Sunday
    let slack = Item(id: 1, source: .slack, title: "", detail: "", waitingSince: at("2026-09-24T10:25:00Z"))
    // macOS puts a narrow no-break space before AM; compare with plain spaces.
    func label(_ i: Item) -> String {
        AgeLabel.text(for: i, scale: AgeScale(), now: now, calendar: cal).replacingOccurrences(of: "\u{202F}", with: " ")
    }
    #expect(label(slack) == "Thu 10:25 AM (14 business hrs ago)")
    let jira = Item(id: 2, source: .jira, title: "", detail: "", lastMyResponse: at("2026-09-24T10:25:00Z"))
    #expect(label(jira) == "Thu 10:25 AM (14 business hrs ago)")
    #expect(label(Item(id: 3, source: .jira, title: "", detail: "")) == "never")
    let fri = Item(id: 4, source: .slack, title: "", detail: "", waitingSince: at("2026-09-25T16:36:00Z"))
    #expect(label(fri) == "Fri 4:36 PM (24 business min ago)")
}

@Test func boomerangCountsBusinessHours() {
    // Wed 16:30 + 2 business hours = Thu 10:30.
    #expect(BusinessClock.date(businessHours: 2, after: at("2026-09-30T16:30:00Z"), calendar: utc) == at("2026-10-01T10:30:00Z"))
    // Fri 16:00 + 2 = Mon 10:00.
    #expect(BusinessClock.date(businessHours: 2, after: at("2026-10-02T16:00:00Z"), calendar: utc) == at("2026-10-05T10:00:00Z"))
}

@Test func hiddenTextShowsOnlyWhoAndWhere() {
    #expect(SlackSource.withoutText("Ann: can you look?") == "Message from Ann")
    #expect(SlackSource.withoutText("Kim in #ops: yes: really") == "Message from Kim in #ops")
    #expect(SlackSource.withoutText("no colon") == "no colon")
}

@Test func botChannelNamesNormalize() {
    #expect(SlackSource.channelKey(" #Security-Logging-Analytics-Alerts ") == "security-logging-analytics-alerts")
}

@Test func alertTitleComesFromBlocks() {
    let blocks: [[String: Any]] = [["type": "header", "text": ["type": "plain_text", "text": "Rule fired: GitLab lag"]],
                                   ["type": "section", "fields": [["type": "mrkdwn", "text": "*Severity:* high"]]]]
    #expect(SlackSource.blockText(blocks) == "Rule fired: GitLab lag")
    #expect(SlackSource.blockText([["type": "section", "fields": [["text": "only field"]]]]) == "only field")
    #expect(SlackSource.blockText(nil) == nil)
}

@Test func dismissedSlackItemStaysDismissedAcrossOffAndOn() throws {
    let s = try tempStore()
    try s.applySlack([st("dm:C1", marker: "1")], answered: [], kinds: all)
    try s.dismiss(try #require(try s.queue().first?.id))
    try s.setPref("slack_enabled", "0")
    try s.setPref("slack_enabled", "1")
    // Same message on the next sync: still dismissed, not re-popped.
    #expect(try s.applySlack([st("dm:C1", marker: "1")], answered: [], kinds: all).isEmpty)
    #expect(try s.queue().isEmpty)
}

@Test func reactionCountsAsLastResponse() {
    let me = "U-me"
    let msgs: [[String: Any]] = [
        ["ts": "100.0", "user": "U-a", "reactions": [["name": "+1", "users": [me]]]],
        ["ts": "200.0", "user": "U-a", "reactions": [["name": "+1", "users": [me, "U-b"]]]],
        ["ts": "300.0", "user": "U-a"],
    ]
    // My last written message was at 50; I reacted to 100 and 200, so only 300 waits.
    #expect(SlackSource.lastResponse(myLastMessage: 50, messages: msgs, me: me) == 200)
    // A later written message wins.
    #expect(SlackSource.lastResponse(myLastMessage: 250, messages: msgs, me: me) == 250)
    // Someone else's reaction doesn't count.
    #expect(SlackSource.lastResponse(myLastMessage: 0, messages: [["ts": "5.0", "reactions": [["users": ["U-b"]]]]], me: me) == 0)
}
