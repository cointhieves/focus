import SwiftUI
import FocusCore

/// FocusSettings form. Every change saves and applies immediately.
struct SettingsView: View {
    @ObservedObject var model: QueueModel
    let onResetPosition: () -> Void
    /// Fixed height when the form is taller than the screen (it scrolls). Nil = natural height.
    var height: CGFloat? = nil
    /// Called with the content's natural height whenever it changes (e.g. Advanced opens).
    var onHeight: (CGFloat) -> Void = { _ in }

    /// Binding to one settings field that saves through the model on every change.
    private func binding(_ key: WritableKeyPath<FocusSettings, Double>) -> Binding<Double> {
        Binding(
            get: { model.settings[keyPath: key] },
            set: { value in
                var s = model.settings
                s[keyPath: key] = value
                model.updateSettings(s)
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            band("General") {
                column { panelSection }
                column { ageSection; slackAgeSection; resetSection }
            }
            band("Integrations") {
                column { JiraSettingsSection(model: model) }
                column { SlackSettingsSection(model: model) }
            }
            band("Try it") {
                column { tryItSection }
            }
        }
        .padding(.vertical, 8)
        .background(GeometryReader { g in
            Color.clear.preference(key: SettingsContentHeight.self, value: g.size.height)
        })
        .onPreferenceChange(SettingsContentHeight.self) { onHeight($0) }
        .modifier(SettingsHeight(height: height))
    }

    /// A titled row of side-by-side columns.
    private func band<C: View>(_ title: String, @ViewBuilder _ columns: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.horizontal, 20).padding(.top, 8)
            HStack(alignment: .top, spacing: 0) { columns() }
        }
    }

    /// One grouped form column; it sizes to its content instead of scrolling.
    private func column<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    private var panelSection: some View {
        Section("Panel") {
            LabeledContent {
                Toggle("", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                    .labelsHidden()
            } label: {
                Text("Open at login")
                if !model.loginNote.isEmpty { Text(model.loginNote) }
            }
            LabeledContent("Faded opacity") {
                Slider(value: binding(\.idleOpacity), in: 0.05...1)
                Text("\(Int(model.settings.idleOpacity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            LabeledContent("Fade after mouse leaves") {
                Stepper("\(Int(model.settings.fadeDelaySeconds))s",
                        value: binding(\.fadeDelaySeconds), in: 1...60, step: 1)
            }
            LabeledContent {
                Stepper("\(Int(model.settings.highlightSeconds))s",
                        value: binding(\.highlightSeconds), in: 1...60, step: 1)
            } label: {
                Text("Light up alerts for")
                Text("An item lights up and shakes when it's added, when someone replies, or when a deadline is near.")
            }
            LabeledContent {
                Stepper(duration(model.settings.snoozeHours), value: binding(\.snoozeHours), in: 0.25...40, step: 0.25)
            } label: {
                Text("Boomerang for")
                Text("Business hours an item stays at the bottom before it comes back.")
            }
            LabeledContent {
                Stepper(model.settings.hideAfterOpenMinutes == 0 ? "Off" : "\(Int(model.settings.hideAfterOpenMinutes)) min",
                        value: binding(\.hideAfterOpenMinutes), in: 0...60, step: 1)
            } label: {
                Text("Hide after opening an item")
                Text("Focus hides while you reply and comes back when you switch to another app, or after this long.")
            }
            Toggle(isOn: Binding(get: { model.settings.hideMessageText },
                                 set: { var s = model.settings; s.hideMessageText = $0; model.updateSettings(s) })) {
                Text("Hide message text")
                Text("Slack items show only who and where. Handy before sharing your screen.")
            }
            LabeledContent("Text size") {
                Slider(value: binding(\.textScale), in: 0.8...1.6, step: 0.1)
                Text(String(format: "%.1fx", model.settings.textScale)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var ageSection: some View {
        Section("Jira age colors (business hours)") {
            LabeledContent("Green until") {
                Stepper("\(Int(model.settings.greenUntilHours))h",
                        value: binding(\.greenUntilHours), in: 1...80, step: 1)
            }
            LabeledContent("Red at") {
                Stepper("\(Int(model.settings.redAtHours))h",
                        value: binding(\.redAtHours),
                        in: (model.settings.greenUntilHours + 1)...160, step: 1)
            }
        }
    }

    private var slackAgeSection: some View {
        Section("Slack age colors (business hours)") {
            LabeledContent("Green until") {
                Stepper(duration(model.settings.slackGreenHours),
                        value: binding(\.slackGreenHours), in: 0.25...40, step: 0.25)
            }
            LabeledContent("Red at") {
                Stepper(duration(model.settings.slackRedHours),
                        value: binding(\.slackRedHours), in: (model.settings.slackGreenHours + 0.25)...80, step: 0.25)
            }
            LabeledContent("Business hours") {
                Stepper(clock(model.settings.workStartHour), value: binding(\.workStartHour), in: 0...23, step: 1)
                Text("to")
                Stepper(clock(model.settings.workEndHour), value: binding(\.workEndHour),
                        in: (model.settings.workStartHour + 1)...24, step: 1)
            }
        }
    }

    private func duration(_ h: Double) -> String {
        let m = Int((h * 60).rounded())
        return m < 60 ? "\(m)m" : m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
    private func clock(_ h: Double) -> String { String(format: "%d:00", Int(h)) }

    private var resetSection: some View {
        Section {
            HStack {
                Button("Reset panel position", action: onResetPosition)
                Spacer()
                Button("Restore defaults") { model.updateSettings(FocusSettings()) }
            }
        }
    }

    private var tryItSection: some View {
        Section {
            // One labeled row per group, stacked, so nothing runs off the edge.
            LabeledContent("Slack") {
                HStack {
                    Button("New DM") { model.simulateSlackNewDM() }
                        .help("A DM arrives: pops to the front, green")
                    Button("More messages") { model.simulateSlackMore() }
                        .help("More messages while it waits: no re-pop, the clock keeps running")
                    Button("Unanswered 2h") { model.simulateSlackOld() }
                        .help("Waiting over 2 business hours: red")
                    Button("You replied") { model.simulateSlackReplied() }
                        .help("You replied or reacted: blue RESPONDED, then gone")
                }.fixedSize()
            }
            LabeledContent("Jira") {
                HStack {
                    Button("Someone replied") { model.simulateJiraReply() }
                        .help("Someone commented on one of your sprint tickets: pops up, below Slack")
                    Button("Mentioned you") { model.simulateJiraMention() }
                        .help("Someone @mentioned you on a ticket outside your sprint")
                    Button("You commented") { model.simulateJiraCommented() }
                        .help("You commented: blue RESPONDED, then gone")
                }.fixedSize()
            }
            LabeledContent("Jira leaves") {
                HStack {
                    Button("Closed") { model.simulateJiraClosed() }
                        .help("Ticket closed in Jira: green CLOSED, then gone")
                    Button("Removed") { model.simulateJiraRemoved() }
                        .help("Moved to To Do, out of the sprint, or reassigned: stays grey until you clear it")
                }.fixedSize()
            }
            LabeledContent("Jira returns") {
                HStack {
                    Button("Back in scope") { model.simulateJiraBackInScope() }
                        .help("A removed ticket comes back with a reply: grey clears, pops to the front")
                    Button("A day later") { model.simulateJiraReturns() }
                        .help("Your comment is one business day old: rejoins the line in amber")
                }.fixedSize()
            }
            LabeledContent("Boomerang") {
                Button("Back in 10s") { model.simulateBoomerang() }.fixedSize()
                    .help("Sends the demo DM to the bottom; it pops back after 10 seconds")
            }
            LabeledContent("Demo items") {
                Button("Remove all") { model.removeDemoItems() }.fixedSize()
            }
        } footer: {
            Text("Demos use your current settings and run through the same code as a real sync, on demo items only. A reply on an item that's already first does nothing, just like a real one; add a New DM to push it down, then try again. If a ticket closes and you comment in the same sync, CLOSED wins.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

private struct SettingsContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct SettingsHeight: ViewModifier {
    let height: CGFloat?
    func body(content: Content) -> some View {
        if let height {
            ScrollView { content }.frame(width: 880, height: height)
        } else {
            content.frame(width: 880).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Advanced" disclosure where the whole row (word included) toggles it, not only the
/// small chevron, which is all a plain DisclosureGroup responds to on macOS.
struct AdvancedGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open, content: content) {
            Button { withAnimation { open.toggle() } } label: {
                Text("Advanced").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// A small editable list: type an entry, press Return (or +) to add it, minus to remove.
/// Entries are trimmed, run through `normalize`, and deduplicated. `onChange` gets the
/// whole new list and is expected to save it.
struct EditableList: View {
    let title: String
    let prompt: String
    let items: [String]
    var normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let onChange: ([String]) -> Void
    @State private var draft = ""

    private func add() {
        let value = normalize(draft)
        draft = ""
        guard !value.isEmpty, !items.contains(value) else { return }
        onChange(items + [value])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            HStack {
                TextField(title, text: $draft, prompt: Text(prompt))
                    .labelsHidden()
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "plus") }
                    .disabled(normalize(draft).isEmpty)
                    .help("Add")
            }
            if !items.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items, id: \.self) { item in
                            HStack {
                                Text(item).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { onChange(items.filter { $0 != item }) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Remove")
                            }
                            .padding(.vertical, 4).padding(.horizontal, 8)
                            if item != items.last { Divider() }
                        }
                    }
                }
                // About five rows visible, then it scrolls.
                .frame(maxHeight: 130)
                .fixedSize(horizontal: false, vertical: items.count <= 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// Slack: on/off, connect, which kinds show, and channels whose bot alerts count.
struct SlackSettingsSection: View {
    @ObservedObject var model: QueueModel

    private var ok: Bool { model.slackStatus.hasPrefix("Connected") || model.slackStatus.hasPrefix("Synced") }
    private var bad: Bool { ["failed", "expired", "not completed", "Could not"].contains { model.slackStatus.contains($0) } }

    var body: some View {
        Section {
            // Same shape as Jira: on/off first, then what's needed to connect, then status.
            Toggle("Show my Slack messages", isOn: Binding(
                get: { model.slackEnabled },
                set: { model.setSlackEnabled($0) }))
            if model.slackEnabled {
                HStack {
                    if model.slackBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    if model.slackConnected {
                        Button("Disconnect") { model.disconnectSlack() }.fixedSize()
                    }
                    Button(model.slackConnected ? "Reconnect" : "Connect Slack") { model.connectSlack() }
                        .fixedSize()
                        .keyboardShortcut(model.slackConnected ? nil : .defaultAction)
                }
            }
            if model.slackEnabled && model.slackConnected {
                LabeledContent("Show") {
                    HStack(spacing: 12) {
                        ForEach([("dm", "DMs"), ("group", "Group DMs"), ("thread", "Threads"), ("mention", "Mentions")], id: \.0) { kind, label in
                            Toggle(label, isOn: Binding(get: { model.slackKinds.contains(kind) },
                                                        set: { model.setSlackKind(kind, $0) }))
                                .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            if model.slackEnabled && model.slackConnected {
                AdvancedGroup {
                    EditableList(title: "Bot alerts from", prompt: "Type a channel name and press Return",
                                 items: model.slackBotChannels.sorted(),
                                 normalize: SlackSource.channelKey,
                                 onChange: { model.setSlackBotChannels($0) })
                    Text("Bots are ignored except in these channels, where an alert that mentions you or one of your groups shows up. React or reply in its thread to clear it. Changes save right away.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Label(model.slackStatus, systemImage: model.slackBusy ? "arrow.triangle.2.circlepath"
                  : ok ? "checkmark.circle.fill" : bad ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(ok ? .green : bad ? .red : .secondary)
        } header: {
            Text("Slack")
        } footer: {
            Text("Connect signs you in as yourself: your own token, kept in this Mac's Keychain, reading only what you can already see in Slack. Nobody else can use it. Turning this off keeps you signed in; Disconnect revokes it. Syncs every 30 seconds.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Jira connection settings. Edits are local until "Save & Test".
struct JiraSettingsSection: View {
    @ObservedObject var model: QueueModel
    @State private var config = JiraConfig()
    @State private var token = ""
    @State private var loaded = false

    private var failed: Bool { model.jiraStatus.contains("failed") }
    private var statusIcon: String {
        model.jiraTesting ? "arrow.triangle.2.circlepath" : failed ? "exclamationmark.triangle.fill"
            : model.jiraStatus.hasPrefix("Connected") || model.jiraStatus.hasPrefix("Synced") ? "checkmark.circle.fill"
            : "info.circle"
    }
    private var statusColor: Color {
        failed ? .red : model.jiraStatus.hasPrefix("Connected") || model.jiraStatus.hasPrefix("Synced") ? .green : .secondary
    }

    var body: some View {
        Section {
            // Takes effect immediately; the fields below still use Save & Test.
            Toggle("Show my sprint tickets", isOn: Binding(
                get: { model.jiraConfig.enabled },
                set: { on in
                    config.enabled = on
                    model.setJiraEnabled(on)
                }))
            Toggle(isOn: Binding(get: { model.jiraMentionsOn }, set: { model.setJiraMentions($0) })) {
                Text("Also show @mentions on other tickets")
                Text("Any ticket where someone mentioned you and you haven't commented since.")
            }
            TextField("Email", text: $config.email, prompt: Text("you@company.com"))
            SecureField("API token", text: $token,
                        prompt: Text(model.hasJiraToken ? "Saved in Keychain (type to replace)" : "Paste token"))
            HStack {
                Link("Create an API token", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                Spacer()
                if model.jiraTesting { ProgressView().controlSize(.small) }
                Button("Save & Test") {
                    config.ignoredAccountIds = model.jiraConfig.ignoredAccountIds   // saved on its own
                    model.saveJira(config, newToken: token)
                    token = ""
                }
                .fixedSize()
            }
            AdvancedGroup {
                EditableList(title: "Ignore comments from", prompt: "Type an Atlassian account ID and press Return",
                             items: model.jiraConfig.ignoredAccountIds,
                             onChange: { model.setJiraIgnored($0) })
                Text("Comments from these Atlassian accounts (bots posting as people) never count as a reply. Changes save right away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Result of the last test/sync, last in the section (same as Slack).
            Label(model.jiraStatus, systemImage: statusIcon)
                .foregroundStyle(statusColor)
        } header: {
            Text("Jira")
        } footer: {
            Text("Save & Test signs you in as yourself: your own API token, kept in this Mac's Keychain, reading only what you can already see in Jira. Nobody else can use it. Turning this off keeps your token saved. Syncs every 15 seconds.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            config = model.jiraConfig
        }
    }
}
