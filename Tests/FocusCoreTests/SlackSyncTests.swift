import Foundation
import Testing
@testable import FocusCore

/// Full Slack sync paths against canned responses. Each test is a real incident.

private let me = "U_ME", mine = "S_MINE", other = "S_OTHER", channel = "C_HELP"
private let now = Date(timeIntervalSince1970: 2_000_000_000)
private func ts(_ minutesAgo: Double) -> String { String(format: "%.6f", now.timeIntervalSince1970 - minutesAgo * 60) }

private func source(_ routes: [FakeNet.Route]) -> SlackSource {
    let (session, _) = FakeNet.session(routes + [
        // Anything not covered above answers "nothing found" rather than failing.
        .init(match: ["search.messages"], status: 200, body: #"{"ok":true,"messages":{"matches":[],"paging":{"pages":1}}}"#),
        .init(match: ["users.info"], status: 200, body: #"{"ok":true,"user":{"id":"U_X","real_name":"Person"}}"#),
        .init(match: ["usergroups.list"], status: 200,
              body: #"{"ok":true,"usergroups":[{"id":"\#(mine)","handle":"my-team","users":["\#(me)","U_TEAMMATE"]}]}"#),
        .init(match: ["conversations.history"], status: 200, body: #"{"ok":true,"messages":[]}"#),
    ])
    return SlackSource(client: SlackClient(session: session), token: "xoxp-test", me: me)
}

private func match(text: String, user: String, at t: String, group: String) -> String {
    #"""
    {"type":"message","user":"\#(user)","ts":"\#(t)","text":"\#(text)",
     "channel":{"id":"\#(channel)","name":"help-channel"},
     "permalink":"https://x.slack.com/archives/\#(channel)/p1?thread_ts=\#(ts(60))",
     "blocks":[{"type":"rich_text","elements":[{"type":"rich_text_section","elements":[{"type":"usergroup","usergroup_id":"\#(group)"}]}]}]}
    """#
}

private func search(_ m: String) -> String { #"{"ok":true,"messages":{"matches":[\#(m)],"paging":{"pages":1}}}"# }

// Slack's search for MY group's tag also returned a reply tagging a different group. It must
// not show up, and must not pull me into its thread.
@Test func otherGroupsTagFromSearchIsIgnored() async throws {
    let src = source([
        .init(match: ["search.messages", "subteam^\(mine)"], status: 200,
              body: search(match(text: "cc <!subteam^\(other)|@other> nvm", user: "U_ASKER", at: ts(5), group: other))),
    ])
    let r = try await src.sync(open: [:], kinds: Set(SlackKind.all), firstRun: false, now: now)
    #expect(r.states.isEmpty)
}

// A real tag of my group shows as one item, and a reply from someone OUTSIDE the group
// doesn't clear it; a teammate's reply does.
@Test func myGroupTagClearsOnlyOnAMemberReply() async throws {
    let tag = match(text: "<!subteam^\(mine)|@my-team> is it down?", user: "U_ASKER", at: ts(10), group: mine)
    func replies(_ extra: String) -> FakeNet.Route {
        .init(match: ["conversations.replies"], status: 200, body: #"""
            {"ok":true,"messages":[{"user":"U_ASKER","ts":"\#(ts(60))"},{"user":"U_ASKER","ts":"\#(ts(10))"}\#(extra)]}
            """#)
    }
    let tagRoute = FakeNet.Route(match: ["search.messages", "subteam^\(mine)"], status: 200, body: search(tag))

    let waiting = try await source([tagRoute, replies(#",{"user":"U_OUTSIDER","ts":"\#(ts(5))"}"#)])
        .sync(open: [:], kinds: Set(SlackKind.all), firstRun: false, now: now)
    #expect(waiting.states.count == 1)
    #expect(waiting.states.first?.title.contains("tagged @my-team") == true)

    let handled = try await source([tagRoute, replies(#",{"user":"U_TEAMMATE","ts":"\#(ts(5))"}"#)])
        .sync(open: [:], kinds: Set(SlackKind.all), firstRun: false, now: now)
    #expect(handled.states.isEmpty)
}
