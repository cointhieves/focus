import SwiftUI
import FocusCore

struct PanelView: View {
    @ObservedObject var model: QueueModel
    @ObservedObject var fade: FadeController
    /// Asks the panel to grow taller by this many points (capped at the screen).
    var onExpand: (CGFloat) -> Void = { _ in }
    /// Asks the panel to undo a "+N more" expansion.
    var onCollapse: () -> Void = {}
    /// Opens the Settings window.
    var onSettings: () -> Void = {}
    /// Opens an item's link (the app hides the panel while you reply).
    var onOpen: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The pointer entered (true) or left the rows: the panel stops / resumes moving on drag.
    var onRowsHover: (Bool) -> Void = { _ in }

    @State private var adding = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    // Geometry used to work out how many rows are actually visible.
    @State private var rowFrames: [Int64: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    /// Drag-to-reorder: the row being dragged, and the row it would land above (-1 = end).
    @State private var dragging: Int64?
    @State private var dropTarget: Int64?
    /// The group a dragged task would join (nil = top level).
    @State private var dropGroup: Int64?
    /// A drag just ended on a row; swallow the click that a mouse-up on a row also sends.
    @State private var dragEndedAt = Date.distantPast
    @State private var hoveringRows = false
    /// True after "+N more" until the panel collapses (Show less, fade, or hide).
    @State private var expanded = false
    /// Set by Show less (outside the ScrollViewReader) to scroll back to the top.
    @State private var scrollToTop = false

    var body: some View {
        // Text and background fade; the color strips on each row do not.
        let contentOpacity = fade.awake ? 1.0 : fade.idleOpacity
        let now = model.now
        let hidden = hiddenCount
        let groupCounts = model.groupCounts
        let groupList = model.groups

        VStack(alignment: .leading, spacing: 6) {
            header.opacity(contentOpacity)

            // The panel height is user-controlled. All items live in the scroll view;
            // how many fit depends on how tall the panel is.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.displayItems) { item in
                            ItemRow(
                                item: item,
                                band: model.scale.band(for: item, now: now),
                                short: shortAge(item, scale: model.scale, now: now),
                                tooltip: "\(item.detail) · \(ageLabel(item, now: now))",
                                contentOpacity: contentOpacity,
                                shakeToken: model.shakeTokens[item.id] ?? 0,
                                highlighted: model.isHighlighted(item.id, now: now)
                                    || (item.isGroup && model.groupHasAlert(item.id))
                                    // The group a dragged task would land in.
                                    || (item.isGroup && dragging != nil && dropGroup == item.id),
                                closing: model.closingPhase(item.id, now: now),
                                textScale: model.settings.textScale,
                                hideText: model.settings.hideMessageText,
                                onSkip: { model.skip(item.id) },
                                onDismiss: { model.dismiss(item.id) },
                                onDone: { model.markDone(item.id) },
                                onBoomerang: { model.toggleBoomerang(item.id) },
                                onOpen: { url in
                                    guard Date().timeIntervalSince(dragEndedAt) > 0.4 else { return }
                                    onOpen(url)
                                },
                                onExpanded: {
                                    // After the expand animation, scroll just enough to show the
                                    // whole row (anchor nil = minimal scroll).
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(item.id) }
                                    }
                                },
                                onEdit: { model.editIdea(item.id, text: $0) },
                                groupCount: groupCounts[item.id] ?? 0,
                                indented: item.groupId != nil,
                                onMakeGroup: { model.makeGroup(item.id) },
                                onUngroup: { model.ungroup(item.id) },
                                groups: groupList,
                                onMoveToGroup: { model.moveTask(item.id, toGroup: $0, before: nil) },
                                onNewGroup: { model.addGroup(near: item.id, above: $0) },
                                onDeleteGroup: { model.deleteGroup(item.id) },
                                onRename: { model.renameGroup(item.id, to: $0) },
                                onAddTask: { model.addTask($0, toGroup: item.id) }
                            )
                            .id(item.id)
                            // Drag a row anywhere; it lands just above the line shown.
                            .opacity(dragging == item.id ? 0.4 : 1)
                            .simultaneousGesture(reorderGesture(item.id))
                            .overlay(alignment: .top) {
                                if dragging != nil, dropTarget == item.id {
                                    // Indented line = lands inside the group.
                                    Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -1)
                                        .padding(.leading, dropGroup != nil ? 18 : 0)
                                }
                            }
                            .background(GeometryReader { geo in
                                Color.clear.preference(
                                    key: RowFramesKey.self,
                                    value: [item.id: geo.frame(in: .named("scroll"))]
                                )
                            })
                        }
                        // Shows where a row dragged past the last one will land.
                        Rectangle().fill(dragging != nil && dropTarget == -1 ? Color.accentColor : .clear)
                            .frame(height: 2)
                            .padding(.leading, dropGroup != nil ? 18 : 0)
                    }
                    .id("top")
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    })
                }
                .coordinateSpace(name: "scroll")
                // Over the rows, a drag reorders instead of moving the panel.
                .onHover { over in
                    hoveringRows = over
                    onRowsHover(over || dragging != nil)
                }
                // Scrolling still works with the wheel/trackpad; the bar is just never drawn.
                .scrollIndicators(.never)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ViewportHeightKey.self, value: geo.size.height)
                })
                .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
                .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
                .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }
                // When the panel fades, return to the regular view: undo any
                // "+N more" expansion and scroll back to the top.
                .onChange(of: scrollToTop) { go in
                    guard go else { return }
                    scrollToTop = false
                    proxy.scrollTo("top", anchor: .top)
                }
                .onReceive(fade.$awake) { awake in
                    guard !awake else { return }
                    // @Published emits BEFORE the value changes. Mutating state here
                    // synchronously swallows the fade redraw, so defer the reset.
                    DispatchQueue.main.async {
                        expanded = false
                        onCollapse()
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
            }

            if let done = model.pendingDone {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Done: \(done.title)").lineLimit(1)
                    Spacer()
                    Button("Undo") { model.undoDone() }
                }
                .font(.system(size: 12 * model.settings.textScale))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
            }

            // Bottom row: new tasks land at the bottom, so this is where you add them.
            HStack(spacing: 8) {
                if adding {
                    TextField("New task, then Return. Add \"by 5pm\" or \"in 30 min\" for a deadline", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onAppear { fieldFocused = true }
                        // Return adds; Return on an empty field just closes (addIdea ignores blanks).
                        .onSubmit { closeAdd(save: true) }
                        .onExitCommand { closeAdd(save: false) }
                } else {
                    Button { adding = true } label: { Label("Add", systemImage: "plus") }
                        .help("Add a task (or press Return while Focus is selected)")
                        .opacity(contentOpacity)
                    Spacer()
                }
                if hidden > 0 {
                    Button("+\(hidden) more") {
                        onExpand(contentHeight - viewportHeight)
                        expanded = true
                    }
                    .opacity(contentOpacity)
                } else if expanded {
                    Button("Show less") {
                        expanded = false
                        onCollapse()
                        scrollToTop = true
                    }
                    .opacity(contentOpacity)
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12 * model.settings.textScale))
        }
        // Return on the focused panel (see AppDelegate). dropFirst: @Published replays
        // its current value on subscribe, which must not open the field at launch.
        .onReceive(model.$addRequests.dropFirst()) { _ in adding = true }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { PanelBackground(opacity: contentOpacity) }
        .ignoresSafeArea()
    }

    /// Items not fully inside the scroll viewport (below the fold, or scrolled past).
    private var hiddenCount: Int {
        guard viewportHeight > 0 else { return 0 }
        let visible = model.items.filter { item in
            guard let f = rowFrames[item.id] else { return false }
            return f.minY >= -1 && f.maxY <= viewportHeight + 1
        }.count
        return model.items.count - visible
    }

    /// Drag a row to reorder. A task can also move into, out of and between groups:
    /// - dropped above a row inside a group, it joins that group just above that row;
    /// - dropped just after a group with the pointer indented, it joins that group at the end;
    /// - otherwise it goes to the top level.
    /// Headings, Jira and Slack rows only move at the top level (a heading takes its group).
    private func reorderGesture(_ id: Int64) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("scroll"))
            .onChanged { g in
                if dragging == nil { dragging = id; onRowsHover(true) }
                let rows = model.displayItems
                guard let me = rows.first(where: { $0.id == id }) else { return }
                let canJoin = me.source == .idea && !me.isGroup
                let y = g.location.y
                let candidates = rows.filter { $0.id != id && (canJoin || $0.groupId == nil) }
                let below = candidates.first { rowFrames[$0.id].map { $0.midY > y } ?? false }
                dropTarget = below?.id ?? -1
                // Which group would it land in?
                if canJoin, let b = below, let g = b.groupId { dropGroup = g; return }
                // Just after a group (or at the end): indented pointer = end of that group.
                let idx = below.flatMap { b in rows.firstIndex { $0.id == b.id } } ?? rows.count
                let prev = rows[..<idx].last { $0.id != id }
                let lastGroup = prev.flatMap { $0.isGroup ? $0.id : $0.groupId }
                dropGroup = canJoin && g.location.x > 40 ? lastGroup : nil
            }
            .onEnded { _ in
                defer { dragging = nil; dropTarget = nil; dropGroup = nil; dragEndedAt = Date(); onRowsHover(hoveringRows) }
                guard dragging == id, let target = dropTarget else { return }
                var before: Int64? = target == -1 ? nil : target
                guard let me = model.displayItems.first(where: { $0.id == id }) else { return }
                // Out of a group, a top-level slot is needed: a row inside a group stands for
                // its heading's position, so land just above that heading.
                if dropGroup == nil, let b = before, let g = model.displayItems.first(where: { $0.id == b })?.groupId {
                    before = g
                }
                if me.source == .idea && !me.isGroup && (dropGroup != nil || me.groupId != nil) {
                    let inGroup = dropGroup.flatMap { g in
                        model.displayItems.first { $0.id == before }?.groupId == g ? before : nil
                    }
                    model.moveTask(id, toGroup: dropGroup, before: dropGroup == nil ? before : inGroup)
                } else {
                    model.place(id, before: before)
                }
            }
    }

    private func closeAdd(save: Bool) {
        if save { model.addIdea(draft) }
        draft = ""
        adding = false
    }

    private var header: some View {
        let scale = model.settings.textScale
        return HStack(spacing: 8) {
            Text("Focus").font(.system(size: 15 * scale, weight: .bold))
            Text("\(model.items.count)")
                .font(.system(size: 11 * scale, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "gearshape").font(.system(size: 12 * scale, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private func ageLabel(_ item: Item, now: Date) -> String {
        AgeLabel.text(for: item, scale: model.scale, now: now)
    }
}

private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Horizontal shake. Animating the token from n to n+1 runs three wiggles and ends at rest.
struct Shake: GeometryEffect {
    var amount: CGFloat = 6
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(animatableData * .pi * 6), y: 0))
    }
}

