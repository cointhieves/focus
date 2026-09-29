import OSLog
import ServiceManagement
import SwiftUI
import FocusCore

private let log = Logger(subsystem: "io.github.omegaleon.focus", category: "queue")

/// UI-side view of the queue. The SQLite store is the source of truth; this model
/// reloads from it after its own writes and when another process (the CLI) writes.
@MainActor
final class QueueModel: ObservableObject {
    @Published private(set) var items: [Item] = []
    /// Incremented per item to trigger its shake animation.
    @Published var shakeTokens: [Int64: Int] = [:]
    /// Time of the most recent pop or first appearance; wakes the panel.
    @Published var lastMovement: Date?
    /// Bumped whenever something lights up (new item, reply, deadline, boomerang back,
    /// farewell). A hidden panel comes back for it: alerts must be seen.
    @Published private(set) var alertTick = 0
    /// Ticks every second so colors and countdowns stay current.
    @Published private(set) var now = Date()

    /// Current settings; the settings window edits these live.
    @Published private(set) var settings = FocusSettings()
    var scale: AgeScale { settings.ageScale }
    var highlightSeconds: TimeInterval { settings.highlightSeconds }
    /// When each item last lit up.
    private var highlightedAt: [Int64: Date] = [:]

    // MARK: - Farewells (closed / responded)

    /// Why a ticket is leaving. Closed is the big event; responded happens far more
    /// often, so it is shorter.
    /// `removed` is an arrival, not a goodbye: the same centered label plays, then the
    /// row stays (grey, small REMOVED on the right) until cleared.
    enum FarewellKind {
        case closed, responded, removed
        /// Shake and light up in the ticket's own color.
        var currentSeconds: TimeInterval { self == .closed ? 1.5 : 1 }
        /// Then the colored label.
        var labelSeconds: TimeInterval { self == .closed ? 3 : 2 }
        var total: TimeInterval { currentSeconds + labelSeconds }
    }
    /// A leaving ticket's last moments on screen: its own color first, then the label,
    /// then gone.
    enum ClosingPhase: Equatable { case current, label(FarewellKind) }
    struct Farewell { let item: Item; let index: Int; let start: Date; let kind: FarewellKind }
    @Published private(set) var farewells: [Farewell] = []

    func closingPhase(_ id: Int64, now: Date) -> ClosingPhase? {
        if let f = farewells.first(where: { $0.item.id == id }) {
            return now.timeIntervalSince(f.start) < f.kind.currentSeconds ? .current : .label(f.kind)
        }
        // REMOVED is driven by the stored removed_at alone, so the shake, the centered
        // banner and the small resting label always happen in that order.
        guard let at = items.first(where: { $0.id == id })?.removedAt else { return nil }
        let elapsed = now.timeIntervalSince(at)
        let kind = FarewellKind.removed
        if elapsed < kind.currentSeconds { return .current }
        return elapsed < kind.total ? .label(.removed) : nil
    }

    /// The queue plus any closing tickets, shown where they used to be.
    /// The queue plus any leaving items. Leaving items play their farewell at the top, so
    /// it's seen even if the row was below the fold (REMOVED rows are popped there by the
    /// store). Several leaving at once stack in the order they started.
    var displayItems: [Item] {
        let leaving = farewells.sorted { $0.start == $1.start ? $0.index < $1.index : $0.start < $1.start }
            .map(\.item).filter { f in !items.contains { $0.id == f.id } }
        return leaving + items
    }

    private func startFarewell(for removed: [(Item, Int)], kind: FarewellKind) {
        guard !removed.isEmpty else { return }
        let start = Date()
        farewells += removed.map { Farewell(item: $0.0, index: $0.1, start: start, kind: kind) }
        alertTick += 1
        withAnimation(.linear(duration: 0.6)) {
            for (item, _) in removed { shakeTokens[item.id, default: 0] += 1 }
        }
    }

    private func expireFarewells(now: Date) {
        let expired: (Farewell) -> Bool = { now.timeIntervalSince($0.start) >= $0.kind.total }
        if farewells.contains(where: expired) {
            withAnimation(.easeOut(duration: 0.3)) { farewells.removeAll(where: expired) }
        }
    }

    func isHighlighted(_ id: Int64, now: Date) -> Bool {
        guard let at = highlightedAt[id] else { return false }
        return now.timeIntervalSince(at) < highlightSeconds
    }

    private let store: Store
    private var lastDataVersion: Int64 = -1
    /// The first sync after a source (or type) is turned back on applies silently: no
    /// shake, no farewells, no panel reappearing for what was already there.
    private var slackQuiet = false
    private var jiraQuiet = false
    /// Set just before a quiet write, so that reload doesn't light anything up.
    private var quietReload = false
    /// Items that appeared or moved after this time get the shake.
    private var watermark = Date()
    private var timer: Timer?
    private var jiraTimer: Timer?
    private var slackTimer: Timer?

    init(store: Store) {
        self.store = store
        do { settings = try store.loadSettings() } catch {
            log.error("settings load failed: \(String(describing: error), privacy: .public)")
        }
        do { jiraConfig = try store.loadJiraConfig() } catch {
            log.error("jira config load failed: \(String(describing: error), privacy: .public)")
        }
        reload()
        setUpLoginItem()
        // Jira: poll every 15s (a sync already running is skipped). API-token traffic is
        // only subject to Jira's per-endpoint burst limits, and a sync is ~3 + N calls.
        jiraTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncJira() }
        }
        syncJira()
        jiraMentionsOn = (try? store.pref("jira_mentions")) != "0"
        slackEnabled = (try? store.pref("slack_enabled")) == "1"
        if let saved = try? store.pref("slack_bot_channels") {
            slackBotChannels = Set(saved.split(separator: ",").map(String.init))
        }
        if let saved = try? store.pref("slack_kinds") {
            slackKinds = Set(saved.split(separator: ",").map(String.init)).intersection(SlackKind.all)
        }
        if slackEnabled { checkSlack() } else { slackStatus = "Off" }
        // Slack: every 30s. Search is limited to ~20 calls a minute and a sync makes ~4.
        slackTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSlack() }
        }
        // PRAGMA data_version changes when another connection commits, so polling it
        // once a second picks up CLI writes cheaply.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - Open at login

    /// Whether Focus is registered to open at login (System Settings → Login Items).
    @Published private(set) var openAtLogin = false
    @Published private(set) var loginNote = ""

    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        openAtLogin = status == .enabled || status == .requiresApproval
        loginNote = status == .requiresApproval ? "Needs approval in System Settings → General → Login Items" : ""
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginNote = "Could not change: \(error.localizedDescription)"
            log.error("login item change failed: \(String(describing: error), privacy: .public)")
        }
        refreshLoginItem()
    }

    /// First launch: turn Open at login on once; afterwards it's entirely the user's choice.
    /// Re-registering on every launch also keeps it pointing at this copy of the app.
    private func setUpLoginItem() {
        let decided = (try? store.pref("login_item_set")) == "1"
        if !decided {
            setOpenAtLogin(true)
            try? store.setPref("login_item_set", "1")
        } else if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.register()
        }
        refreshLoginItem()
    }

    // MARK: - Actions

    /// Saves settings and applies them immediately (values are clamped to valid ranges).
    func updateSettings(_ new: FocusSettings) {
        do { settings = try store.saveSettings(new) } catch {
            log.error("settings save failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Bumped to ask the panel to open its add field (Return on the focused panel).
    @Published private(set) var addRequests = 0
    func requestAdd() { addRequests += 1 }

    func skip(_ id: Int64) { write { try store.skip(id) } }

    /// Boomerang: to the bottom for `snoozeHours` business hours; on a snoozed item, back now.
    func toggleBoomerang(_ id: Int64) {
        if items.first(where: { $0.id == id })?.snoozedUntil != nil {
            write { try store.unsnooze(id) }
            return
        }
        let until = BusinessClock.date(businessHours: settings.snoozeHours, after: Date(),
                                       startHour: settings.workStartHour, endHour: settings.workEndHour)
        write { try store.snooze(id, until: until) }
    }

    /// Try it: boomerang the demo DM for 10 seconds (real time) to watch it come back.
    func simulateBoomerang() {
        if !items.contains(where: { $0.externalId == "dm:DEMO-S1" }) { simulateSlackNewDM() }
        guard let demo = items.first(where: { $0.externalId == "dm:DEMO-S1" }) else { return }
        write { try store.snooze(demo.id, until: Date().addingTimeInterval(10)) }
    }
    func dismiss(_ id: Int64) { write { try store.dismiss(id) } }

    // MARK: - Jira

    @Published private(set) var jiraConfig = JiraConfig()
    /// One-line status for Settings: last sync result or the error.
    @Published private(set) var jiraStatus = "Not connected"
    @Published private(set) var jiraSyncing = false

    /// Token read from the Keychain at most once per launch. Each Keychain read can
    /// trigger a macOS permission prompt, so it is cached in memory.
    private var cachedToken: String?
    private var tokenLoaded = false
    private var jiraToken: String? {
        if !tokenLoaded {
            cachedToken = Keychain.readToken()
            tokenLoaded = true
        }
        return cachedToken
    }
    var hasJiraToken: Bool { jiraToken != nil }

    /// Saves the Jira settings (and the token, if a new one was typed), then tests and syncs.
    func saveJira(_ config: JiraConfig, newToken: String) {
        do {
            let token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                try Keychain.saveToken(token)
                cachedToken = token
                tokenLoaded = true
            }
            try store.saveJiraConfig(config)
            jiraConfig = try store.loadJiraConfig()
        } catch {
            jiraStatus = "Save failed: \(error)"
            return
        }
        testJira()
    }

    /// Turns the Jira integration on or off right away (no Save needed).
    func setJiraEnabled(_ on: Bool) {
        var c = jiraConfig
        c.enabled = on
        do {
            try store.saveJiraConfig(c)
            jiraConfig = c
        } catch {
            jiraStatus = "Save failed: \(error)"
            return
        }
        if on {
            jiraQuiet = true
            syncJira()
        } else {
            // Hidden, not deleted: turning it back on restores them quietly.
            reload()
            jiraStatus = "Off"
        }
    }

    /// Checks the credentials against Jira and reports who they belong to. When the
    /// integration is on, a sync follows.
    func testJira() {
        guard !jiraConfig.email.isEmpty, let token = jiraToken else {
            jiraStatus = "Add your email and API token"
            return
        }
        jiraSyncing = true
        jiraStatus = "Testing connection…"
        let client = JiraClient(config: jiraConfig, token: token)
        Task {
            do {
                let me = try await client.myself()
                let name = me.displayName ?? me.accountId
                jiraSyncing = false
                if jiraConfig.enabled {
                    jiraStatus = "Connected as \(name). Syncing…"
                    syncJira()
                } else {
                    jiraStatus = "Connected as \(name). Turn on \"Show my sprint tickets\" to add them to Focus."
                }
            } catch {
                jiraSyncing = false
                jiraStatus = "Connection failed: \(error)"
            }
        }
    }

    /// Pulls sprint tickets from Jira and applies them to the queue.
    func syncJira(force: Bool = false) {
        guard jiraConfig.enabled, !jiraSyncing else { return }
        guard !jiraConfig.site.isEmpty else {
            jiraStatus = "Jira isn't set up in this build (JiraSite in Resources/Org.plist; see README)"
            return
        }
        jiraStatus = "Syncing…"
        guard !jiraConfig.email.isEmpty, let token = jiraToken else {
            jiraStatus = "Add your email and API token"
            return
        }
        jiraSyncing = true
        let client = JiraClient(config: jiraConfig, token: token)
        let greenUntil = settings.greenUntilHours
        let (workStart, workEnd) = (settings.workStartHour, settings.workEndHour)
        let site = URL(string: jiraConfig.site)
        Task {
            do {
                let result = try await client.fetchStates(greenUntilHours: greenUntil, workStartHour: workStart, workEndHour: workEnd)
                let states = result.states
                let popped = applySync(result, site: site)
                var mentionCount = 0
                if !jiraMentionsOn { jiraQuiet = false }
                if jiraMentionsOn {
                    // First run looks back 30 days for live threads; after that, 3 days catches
                    // every new mention. Items already shown are re-checked until answered.
                    let first = (try? store.pref("jira_mentions_synced_once")) != "1"
                    let m = try await client.fetchMentions(days: first ? 30 : 3, open: try store.mentionKeys(),
                                                           skip: Set(states.map(\.key)))
                    applyMentions(m, site: site)
                    try? store.setPref("jira_mentions_synced_once", "1")
                    mentionCount = items.filter { $0.externalId?.hasPrefix("mention:") == true }.count
                }
                let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                let total = items.filter { $0.source == .jira && $0.externalId?.contains("DEMO-") != true }.count
                jiraStatus = "Synced at \(t): \(total) ticket\(total == 1 ? "" : "s") need attention"
                    + (mentionCount > 0 ? " (\(mentionCount) mention\(mentionCount == 1 ? "" : "s"))" : "")
                log.notice("jira sync: \(states.count, privacy: .public) states, popped \(popped.joined(separator: ","), privacy: .public)")
            } catch {
                jiraStatus = "Sync failed: \(error)"
                log.error("jira sync failed: \(String(describing: error), privacy: .public)")
            }
            jiraSyncing = false
        }
    }

    // MARK: Jira mentions

    /// Whether mentions on tickets outside my sprint show. On by default.
    @Published private(set) var jiraMentionsOn = true

    func setJiraMentions(_ on: Bool) {
        try? store.setPref("jira_mentions", on ? "1" : "0")
        jiraMentionsOn = on
        if on { jiraQuiet = true; syncJira() } else { reload() }
    }

    /// Applies a mention result: answered play RESPONDED, Done play CLOSED.
    private func applyMentions(_ m: JiraMentionResult, site: URL?, limitTo: Set<String>? = nil) {
        var closing: [(Item, Int)] = [], responded: [(Item, Int)] = []
        for (index, item) in displayItems.enumerated() {
            guard let ext = item.externalId, ext.hasPrefix("mention:"),
                  !farewells.contains(where: { $0.item.id == item.id }) else { continue }
            let key = String(ext.dropFirst(8))
            guard limitTo?.contains(key) ?? !key.hasPrefix("DEMO-") else { continue }
            if m.closed.contains(key) { closing.append((item, index)) }
            else if m.answered.contains(key) { responded.append((item, index)) }
        }
        let quiet = jiraQuiet && limitTo == nil
        quietReload = quiet
        write { try store.applyJiraMentions(m.states, remove: m.answered.union(m.closed), site: site, limitTo: limitTo) }
        quietReload = false
        if quiet { jiraQuiet = false; return }   // mentions are applied last in a Jira sync
        startFarewell(for: closing, kind: .closed)
        startFarewell(for: responded, kind: .responded)
    }

    /// Try it: someone mentions you on a ticket outside your sprint.
    func simulateJiraMention() {
        let key = "DEMO-M1"
        let st = JiraMentionState(key: key, summary: "Demo: can you check why these events have no source IP?",
                                  mentionedBy: "Alex", waitingSince: Date(), marker: UUID().uuidString)
        applyMentions(JiraMentionResult(states: [st], answered: [], closed: []), site: nil, limitTo: [key])
    }

    /// Applies one sync result and starts farewells for tickets on screen that leave:
    /// CLOSED if done in Jira (wins), RESPONDED if still mine and in progress but I
    /// replied. Anything else that left scope is marked removed by the store.
    /// The Try it demos call this too, with `limitTo` their demo key, so they exercise
    /// exactly the logic a real sync uses.
    @discardableResult
    private func applySync(_ result: JiraSyncResult, site: URL?, limitTo: Set<String>? = nil) -> [String] {
        let needed = Set(result.states.map(\.key))
        var closing: [(Item, Int)] = [], responded: [(Item, Int)] = []
        for (index, item) in displayItems.enumerated() where item.source == .jira {
            guard let key = item.externalId, !needed.contains(key),
                  limitTo?.contains(key) ?? !key.hasPrefix("DEMO-"),
                  !farewells.contains(where: { $0.item.id == item.id }) else { continue }
            if result.doneKeys.contains(key) { closing.append((item, index)) }
            else if result.inScopeKeys.contains(key) && !item.removed { responded.append((item, index)) }
        }
        var popped: [String] = []
        let quiet = jiraQuiet && limitTo == nil
        quietReload = quiet
        write { popped = try store.applyJira(result.states, inScopeKeys: result.inScopeKeys,
                                             doneKeys: result.doneKeys, limitTo: limitTo, site: site) }
        quietReload = false
        if !quiet {
            startFarewell(for: closing, kind: .closed)
            startFarewell(for: responded, kind: .responded)
        }
        return popped
    }

    // MARK: - Slack (spike: sign-in only, nothing enters the queue yet)

    @Published private(set) var slackStatus = "Not connected"
    @Published private(set) var slackBusy = false
    /// Read from the Keychain once per launch (each read can prompt), then kept in memory.
    private var slackTokens: SlackTokens? = Keychain.readSlackTokens()
    private var slackCallback: OAuthCallbackServer?
    var slackConnected: Bool { slackTokens != nil }
    /// Whether Slack is on. Off keeps the sign-in, so turning it back on needs no reconnect.
    @Published private(set) var slackEnabled = false

    func setSlackEnabled(_ on: Bool) {
        do { try store.setPref("slack_enabled", on ? "1" : "0") } catch {
            slackStatus = "Save failed: \(error)"
            return
        }
        slackEnabled = on
        if !on {
            slackStatus = "Off"
            reload()   // hidden, not deleted: turning it back on restores them quietly
        } else if slackConnected { slackQuiet = true; checkSlack() }
        else { slackStatus = "Not connected" }
    }

    /// Opens Slack's consent page in the browser and waits for the redirect.
    func connectSlack() {
        guard !SlackConfig.clientId.isEmpty else {
            slackStatus = "Slack isn't set up in this build (SlackClientID in Resources/Org.plist; see README)"
            return
        }
        slackCallback?.cancel()
        let verifier = PKCE.randomToken(), state = PKCE.randomToken()
        let server: OAuthCallbackServer
        do {
            server = try OAuthCallbackServer(port: SlackConfig.callbackPort, path: SlackConfig.callbackPath, state: state)
        } catch {
            slackStatus = "Could not start sign-in: \(error)"
            return
        }
        slackCallback = server
        slackBusy = true
        slackStatus = "Waiting for you to click Allow in the browser…"
        server.start { [weak self] outcome in
            Task { @MainActor in self?.finishSlackSignIn(outcome, verifier: verifier) }
        }
        NSWorkspace.shared.open(SlackClient.authorizeURL(challenge: PKCE.challenge(for: verifier), state: state))
    }

    private func finishSlackSignIn(_ outcome: OAuthCallbackServer.Outcome, verifier: String) {
        slackCallback = nil
        switch outcome {
        case .denied(let why):
            slackBusy = false
            slackStatus = "Sign-in not completed: \(why)"
            log.notice("slack sign-in denied: \(why, privacy: .public)")
        case .failed(let why):
            slackBusy = false
            slackStatus = why == "cancelled" ? slackStatus : "Sign-in failed: \(why)"
            log.error("slack sign-in failed: \(why, privacy: .public)")
        case .code(let code):
            slackStatus = "Finishing sign-in…"
            Task {
                do {
                    let tokens = try await SlackClient().exchange(code: code, verifier: verifier)
                    try Keychain.saveSlackTokens(tokens)
                    slackTokens = tokens
                    log.notice("slack sign-in ok, rotating=\(tokens.refreshToken != nil, privacy: .public)")
                    slackBusy = false
                    checkSlack()
                } catch {
                    slackBusy = false
                    slackStatus = "Sign-in failed: \(error)"
                    log.error("slack exchange failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    func disconnectSlack() {
        slackCallback?.cancel()
        // Kill the tokens at Slack too, so they stop working everywhere, not just on this Mac.
        if let t = slackTokens {
            Task {
                await SlackClient().revoke(t.accessToken)
                if let r = t.refreshToken { await SlackClient().revoke(r) }
            }
        }
        Keychain.deleteSlackTokens()
        slackTokens = nil
        slackSource = nil
        write { try store.deleteSlackItems() }
        slackBusy = false
        slackStatus = "Not connected"
    }

    /// A usable access token, rotating it first when it is about to expire.
    /// Refresh tokens are single use, so the new pair is saved before anything else.
    private func validSlackToken() async throws -> String {
        guard var tokens = slackTokens else { throw SlackError("not connected") }
        if tokens.needsRefresh() {
            tokens = try await SlackClient().refresh(tokens)
            try Keychain.saveSlackTokens(tokens)
            slackTokens = tokens
            log.notice("slack token refreshed")
        }
        return tokens.accessToken
    }

    // MARK: Slack sync

    /// Which kinds show: dm, group, thread, mention. All on by default.
    @Published private(set) var slackKinds = Set(SlackKind.all)
    private var slackSyncing = false
    private var slackSource: SlackSource?
    private lazy var slackMe: String = slackTokens?.userId ?? ""

    /// Channels where bot alerts that mention me or my groups count (names, normalized).
    @Published private(set) var slackBotChannels: Set<String> = []

    func setSlackBotChannels(_ text: String) {
        let names = Set(text.split(separator: ",").map { SlackSource.channelKey(String($0)) }.filter { !$0.isEmpty })
        slackBotChannels = names
        try? store.setPref("slack_bot_channels", names.sorted().joined(separator: ","))
        syncSlack()
    }

    func setSlackKind(_ kind: String, _ on: Bool) {
        if on { slackKinds.insert(kind) } else { slackKinds.remove(kind) }
        try? store.setPref("slack_kinds", SlackKind.all.filter(slackKinds.contains).joined(separator: ","))
        reload()   // turned-off kinds are hidden, not deleted
        if on { slackQuiet = true; syncSlack() }
    }

    func syncSlack() {
        guard slackEnabled, slackTokens != nil, !slackSyncing, !slackBusy else { return }
        slackSyncing = true
        Task {
            defer { slackSyncing = false }
            do {
                let token = try await validSlackToken()
                if slackMe.isEmpty { slackMe = try await SlackClient().authTest(token: token).userId }
                if slackSource == nil || slackSource?.token != token {
                    // Keep the user-name cache across token rotation.
                    slackSource = slackSource.map { $0.with(token: token) } ?? SlackSource(token: token, me: slackMe)
                }
                let firstRun = (try? store.pref("slack_synced_once")) != "1"
                let result = try await slackSource!.sync(open: try store.slackMarkers(), kinds: slackKinds, firstRun: firstRun,
                                                         botChannels: slackBotChannels)
                applySlackSync(result)
                try? store.setPref("slack_synced_once", "1")
                let n = items.filter { $0.source == .slack }.count
                let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                slackStatus = "Synced at \(t): \(n) conversation\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") you"
                log.notice("slack sync: \(result.states.count, privacy: .public) waiting, \(result.answered.count, privacy: .public) answered")
            } catch let e as SlackError where ["invalid_auth", "token_revoked", "token_expired", "account_inactive"].contains(e.code ?? "") {
                slackStatus = "Slack sign-in expired (\(e.code ?? "")). Connect again."
            } catch {
                slackStatus = "Slack sync failed: \(error)"
                log.error("slack sync failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Applies a Slack result; answered items on screen play RESPONDED. The Try it demos
    /// call this with `limitTo` their demo key, so they run the same logic.
    private func applySlackSync(_ result: SlackSyncResult, limitTo: Set<String>? = nil) {
        var responded: [(Item, Int)] = []
        for (index, item) in displayItems.enumerated() where item.source == .slack {
            guard let key = item.externalId, result.answered.contains(key),
                  limitTo?.contains(key) ?? !key.contains("DEMO-"),
                  !farewells.contains(where: { $0.item.id == item.id }) else { continue }
            responded.append((item, index))
        }
        let quiet = slackQuiet && limitTo == nil
        quietReload = quiet
        write { try store.applySlack(result.states, answered: result.answered, kinds: slackKinds, limitTo: limitTo) }
        quietReload = false
        if quiet { slackQuiet = false; return }
        startFarewell(for: responded, kind: .responded)
    }

    /// Confirms the saved sign-in still works and shows who it belongs to.
    func checkSlack() {
        guard slackEnabled, slackTokens != nil, !slackBusy else { return }
        slackBusy = true
        Task {
            do {
                let who = try await SlackClient().authTest(token: try await validSlackToken())
                slackStatus = "Connected as \(who.user) in \(who.team)"
                if slackMe.isEmpty { slackMe = who.userId }
                slackBusy = false
                syncSlack()
                return
            } catch let e as SlackError where ["invalid_auth", "token_revoked", "token_expired", "account_inactive"].contains(e.code ?? "") {
                slackStatus = "Slack sign-in expired (\(e.code ?? "")). Connect again."
            } catch {
                slackStatus = "Slack check failed: \(error)"
            }
            slackBusy = false
        }
    }

    // MARK: - Done with undo

    /// A task marked done but not yet deleted; shown in the Undo bar.
    @Published private(set) var pendingDone: Item?
    private var pendingDoneWork: DispatchWorkItem?
    var undoSeconds: TimeInterval = 5

    /// Hides the task now and deletes it after `undoSeconds` unless undone.
    func markDone(_ id: Int64) {
        commitPendingDone()   // only one pending at a time
        guard let item = items.first(where: { $0.id == id }) else { return }
        pendingDone = item
        items.removeAll { $0.id == id }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.commitPendingDone() }
        }
        pendingDoneWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + undoSeconds, execute: work)
    }

    func undoDone() {
        pendingDoneWork?.cancel()
        pendingDoneWork = nil
        pendingDone = nil
        reload()
    }

    /// Deletes the pending task now. Also called on app quit.
    func commitPendingDone() {
        pendingDoneWork?.cancel()
        pendingDoneWork = nil
        guard let item = pendingDone else { return }
        pendingDone = nil
        write { try store.deleteIdea(item.id) }
    }
    func addIdea(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        write { try store.addIdea(text) }
    }

    // MARK: - Simulate (Settings "Try it" section)

    func removeDemoItems() { write { try store.deleteDemoItems() } }

    // Slack transitions, through applySlackSync on a demo conversation only.

    private func demoSlack(_ marker: String, since: Date, title: String) -> SlackSyncResult {
        SlackSyncResult(states: [SlackItemState(key: "dm:DEMO-S1", title: title, detail: "DM", url: nil,
                                                waitingSince: since, marker: marker)], answered: [])
    }

    /// A new DM: pops to the front, green.
    func simulateSlackNewDM() {
        applySlackSync(demoSlack(UUID().uuidString, since: Date(), title: "Ann: got a sec to look at the deploy script?"),
                       limitTo: ["dm:DEMO-S1"])
    }

    /// More messages while it waits: title updates, no re-pop, clock keeps running.
    func simulateSlackMore() {
        if !items.contains(where: { $0.externalId == "dm:DEMO-S1" }) { simulateSlackNewDM() }
        applySlackSync(demoSlack(UUID().uuidString, since: Date(), title: "Ann: also, the dashboard is empty again"),
                       limitTo: ["dm:DEMO-S1"])
    }

    /// Unanswered for over 2 business hours: red.
    func simulateSlackOld() {
        removeSlackDemo()
        let since = BusinessClock.date(businessHours: settings.slackRedHours + 0.5, before: Date(),
                                       startHour: settings.workStartHour, endHour: settings.workEndHour)
        applySlackSync(demoSlack(UUID().uuidString, since: since, title: "Ann: any update on this?"), limitTo: ["dm:DEMO-S1"])
    }

    /// You replied or reacted: blue RESPONDED, then gone.
    func simulateSlackReplied() {
        if !items.contains(where: { $0.externalId == "dm:DEMO-S1" }) {
            simulateSlackNewDM()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.simulateSlackReplied() }
            }
            return
        }
        applySlackSync(SlackSyncResult(states: [], answered: ["dm:DEMO-S1"]), limitTo: ["dm:DEMO-S1"])
    }

    private func removeSlackDemo() {
        write { try store.applySlack([], answered: ["dm:DEMO-S1"], kinds: slackKinds, limitTo: ["dm:DEMO-S1"]) }
    }

    // Jira transitions. Each demo feeds synthetic sync results for one DEMO ticket
    // through applySync, the same path a real sync takes.

    private func demoState(_ key: String, _ title: String, myLastComment: Date?, waiting: Bool) -> JiraTicketState {
        JiraTicketState(key: key, summary: title, myLastComment: myLastComment,
                        waitingOnMe: waiting, changeMarker: waiting ? "reply-\(UUID().uuidString)" : "none")
    }

    /// Shows the demo ticket (needing a response), then after a beat applies `leave`.
    private func demoLeave(_ key: String, _ title: String, leave: JiraSyncResult) {
        let st = demoState(key, title, myLastComment: nil, waiting: false)
        applySync(JiraSyncResult(states: [st], doneKeys: [], inScopeKeys: [key]), site: nil, limitTo: [key])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { _ = self?.applySync(leave, site: nil, limitTo: [key]) }
        }
    }

    /// Ticket closed in Jira: CLOSED farewell.
    func simulateJiraClosed() {
        demoLeave("DEMO-1", "Demo ticket that will close",
                  leave: JiraSyncResult(states: [], doneKeys: ["DEMO-1"], inScopeKeys: []))
    }

    /// You commented; the ticket is still yours and in progress: RESPONDED farewell.
    func simulateJiraResponded() {
        demoLeave("DEMO-2", "Demo ticket you're about to comment on",
                  leave: JiraSyncResult(states: [], doneKeys: [], inScopeKeys: ["DEMO-2"]))
    }

    /// Ticket moved to To Do / out of the sprint / reassigned: stays greyed as REMOVED.
    func simulateJiraRemoved() {
        demoLeave("DEMO-3", "Demo ticket moved back to To Do",
                  leave: JiraSyncResult(states: [], doneKeys: [], inScopeKeys: []))
    }

    /// A removed ticket comes back into scope with a reply waiting: the grey clears and it
    /// pops to the front. Removes the demo first if it isn't showing yet.
    func simulateJiraBackInScope() {
        let key = "DEMO-3"
        let back = { [weak self] in
            guard let self else { return }
            let st = self.demoState(key, "Demo ticket moved back to To Do", myLastComment: nil, waiting: true)
            self.applySync(JiraSyncResult(states: [st], doneKeys: [], inScopeKeys: [key]), site: nil, limitTo: [key])
        }
        if items.contains(where: { $0.externalId == key && $0.removed }) { back(); return }
        simulateJiraRemoved()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { back() } }
    }

    /// Your comment is now 24 weekday hours old: the ticket rejoins the age line at the
    /// start of the amber ramp.
    func simulateJiraReturns() {
        let key = "DEMO-4"
        let st = demoState(key, "Demo ticket you commented on yesterday",
                           myLastComment: BusinessClock.date(businessHours: settings.greenUntilHours, before: Date(),
                                                             startHour: settings.workStartHour, endHour: settings.workEndHour),
                           waiting: false)
        applySync(JiraSyncResult(states: [st], doneKeys: [], inScopeKeys: [key]), site: nil, limitTo: [key])
    }

    /// Try it: you comment. Every demo ticket waiting on you (reply or mention) plays
    /// RESPONDED and leaves, like a real sync after your comment. With none showing, it
    /// adds a reply first so there's something to answer.
    func simulateJiraCommented() {
        let reply = items.contains { $0.externalId == "DEMO-5" }
        let mention = items.contains { $0.externalId == "mention:DEMO-M1" }
        guard reply || mention else {
            simulateJiraReply()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.simulateJiraCommented() }
            }
            return
        }
        if reply {
            // Still my in-progress ticket, no longer needing a response: RESPONDED.
            applySync(JiraSyncResult(states: [], doneKeys: [], inScopeKeys: ["DEMO-5"]), site: nil, limitTo: ["DEMO-5"])
        }
        if mention {
            applyMentions(JiraMentionResult(states: [], answered: ["DEMO-M1"], closed: []), site: nil, limitTo: ["DEMO-M1"])
        }
    }

    /// Someone replies on a demo ticket: it pops, through the same path as a real sync.
    /// Never touches real tickets.
    func simulateJiraReply() {
        let st = demoState("DEMO-5", "Demo ticket someone just replied on",
                           myLastComment: BusinessClock.date(businessHours: 3, before: Date(),
                                                             startHour: settings.workStartHour, endHour: settings.workEndHour),
                           waiting: true)
        applySync(JiraSyncResult(states: [st], doneKeys: [], inScopeKeys: ["DEMO-5"]), site: nil, limitTo: ["DEMO-5"])
    }

    // MARK: - Loading

    private func write(_ change: () throws -> Void) {
        do { try change() } catch { log.error("write failed: \(String(describing: error), privacy: .public)") }
        reload()
    }

    private func tick() {
        now = Date()
        expireFarewells(now: now)
        // Deadline warnings are time-driven, so the long-running app evaluates them.
        do {
            if try !store.wakeSnoozed(now: now).isEmpty {
                reload()
                return
            }
            let warned = try store.advanceDeadlines(now: now)
            if !warned.isEmpty {
                log.notice("deadline warning for ids \(warned.map(String.init).joined(separator: ","), privacy: .public)")
                reload()
                return
            }
        } catch {
            log.error("deadline check failed: \(String(describing: error), privacy: .public)")
        }
        reloadIfChangedElsewhere()
    }

    private func reloadIfChangedElsewhere() {
        guard let version = try? store.dataVersion(), version != lastDataVersion else { return }
        reload()
    }

    private func reload() {
        do {
            let fresh = try store.queue()
            lastDataVersion = try store.dataVersion()
            let moved = fresh.filter { $0.movedAt > watermark }
            // Keep a task pending deletion hidden while its Undo bar is showing.
            items = fresh.filter { $0.id != pendingDone?.id }
            guard let newest = moved.map(\.movedAt).max() else { return }
            watermark = newest
            if quietReload { quietReload = false; return }
            withAnimation(.linear(duration: 0.6)) {
                for item in moved {
                    shakeTokens[item.id, default: 0] += 1
                    highlightedAt[item.id] = Date()
                }
            }
            lastMovement = Date()
            alertTick += 1
        } catch {
            log.error("reload failed: \(String(describing: error), privacy: .public)")
        }
    }
}
