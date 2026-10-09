import Foundation
import Testing
@testable import FocusCore

/// Full Jira sync paths against canned responses. Each test is a real incident.

private func client(_ routes: [FakeNet.Route]) -> (JiraClient, String) {
    var config = JiraConfig()
    config.site = "https://example.atlassian.net"
    config.email = "me@example.com"
    let (session, id) = FakeNet.session(routes)
    return (JiraClient(config: config, token: "t", session: session), id)
}

// Jira's search index lagged a status change: the In Progress filter still returned a ticket
// whose own status was already Done. It must be treated as Done (CLOSED), not still waiting.
@Test func indexLagTicketIsTreatedAsDone() async throws {
    let (c, _) = client([
        JiraFixture.myself(),
        .init(match: ["search/jql", #"statusCategory = "Done""#], status: 200, body: JiraFixture.issues([])),
        .init(match: ["search/jql", #"statusCategory = "In Progress""#], status: 200,
              body: JiraFixture.issues([("ABC-1", "done"), ("ABC-2", "indeterminate")])),
        .init(match: ["/issue/ABC-2/comment"], status: 200, body: JiraFixture.comments([])),
    ])
    let r = try await c.fetchStates(greenUntilHours: 8)
    #expect(r.doneKeys.contains("ABC-1"))
    #expect(!r.states.map(\.key).contains("ABC-1"))
    #expect(r.states.map(\.key) == ["ABC-2"])
}

// Any human comment after mine pops a sprint ticket, no @mention needed; an app account doesn't.
@Test func sprintTicketWaitsOnAnyHumanReply() async throws {
    let (c, _) = client([
        JiraFixture.myself(),
        .init(match: ["search/jql", #"statusCategory = "Done""#], status: 200, body: JiraFixture.issues([])),
        .init(match: ["search/jql", #"statusCategory = "In Progress""#], status: 200,
              body: JiraFixture.issues([("ABC-1", "indeterminate")])),
        .init(match: ["/issue/ABC-1/comment"], status: 200, body: JiraFixture.comments([
            ("2", "bob", "2030-01-01T11:00:00.000+0000"),
            ("1", JiraFixture.me, "2030-01-01T10:00:00.000+0000"),
        ])),
    ])
    let r = try await c.fetchStates(greenUntilHours: 8, now: ISO8601DateFormatter().date(from: "2030-01-01T12:00:00Z")!)
    #expect(r.states.first?.waitingOnMe == true)
    #expect(r.states.first?.changeMarker == "2")
}

// An empty sprint result comes back as an empty scope (the app layer holds it for a sync).
@Test func emptySprintResultHasEmptyScope() async throws {
    let (c, _) = client([
        JiraFixture.myself(),
        .init(match: ["search/jql"], status: 200, body: JiraFixture.issues([])),
    ])
    let r = try await c.fetchStates(greenUntilHours: 8)
    #expect(r.inScopeKeys.isEmpty && r.states.isEmpty)
}

// Reported ticket in ANOTHER team's project: an untagged comment counts. In MY team's project
// someone else works it, so only an @mention counts.
@Test func reportedTicketDependsOnTeamProject() async throws {
    let comment = #"{"comments":[{"id":"9","author":{"accountId":"agent","accountType":"atlassian","displayName":"Agent"},"created":"2030-01-01T11:00:00.000+0000","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Leon, please do X"}]}]}}],"total":1,"startAt":0}"#
    func issue(_ key: String) -> FakeNet.Route {
        .init(match: ["/rest/api/3/issue/\(key)", "fields="], status: 200,
              body: #"{"key":"\#(key)","fields":{"summary":"s","status":{"statusCategory":{"key":"indeterminate"}},"reporter":{"accountId":"\#(JiraFixture.me)","displayName":"Me"},"created":"2030-01-01T09:00:00.000+0000"}}"#)
    }
    let (c, _) = client([
        JiraFixture.myself(),
        .init(match: ["search/jql"], status: 200, body: JiraFixture.issues([("OPS-1", "indeterminate"), ("ABC-7", "indeterminate")])),
        issue("OPS-1"), issue("ABC-7"),
        .init(match: ["/issue/OPS-1/comment"], status: 200, body: comment),
        .init(match: ["/issue/ABC-7/comment"], status: 200, body: comment),
    ])
    let r = try await c.fetchMentions(days: 3, open: [], skip: [], includeReported: true, teamProjects: ["ABC"])
    #expect(r.states.map(\.key) == ["OPS-1"])
    #expect(r.states.first?.viaReport == true)
}
