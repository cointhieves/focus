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

    @State private var adding = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    // Geometry used to work out how many rows are actually visible.
    @State private var rowFrames: [Int64: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // Text and background fade; the color strips on each row do not.
        let contentOpacity = fade.awake ? 1.0 : fade.idleOpacity
        let now = model.now
        let hidden = hiddenCount

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
                                highlighted: model.isHighlighted(item.id, now: now),
                                closing: model.closingPhase(item.id, now: now),
                                textScale: model.settings.textScale,
                                hideText: model.settings.hideMessageText,
                                onSkip: { model.skip(item.id) },
                                onDismiss: { model.dismiss(item.id) },
                                onDone: { model.markDone(item.id) },
                                onBoomerang: { model.toggleBoomerang(item.id) },
                                onOpen: onOpen,
                                onExpanded: {
                                    // After the expand animation, scroll just enough to show the
                                    // whole row (anchor nil = minimal scroll).
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(item.id) }
                                    }
                                }
                            )
                            .id(item.id)
                            .background(GeometryReader { geo in
                                Color.clear.preference(
                                    key: RowFramesKey.self,
                                    value: [item.id: geo.frame(in: .named("scroll"))]
                                )
                            })
                        }
                    }
                    .id("top")
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    })
                }
                .coordinateSpace(name: "scroll")
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
                .onReceive(fade.$awake) { awake in
                    guard !awake else { return }
                    // @Published emits BEFORE the value changes. Mutating state here
                    // synchronously swallows the fade redraw, so defer the reset.
                    DispatchQueue.main.async {
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
                    Button("+\(hidden) more") { onExpand(contentHeight - viewportHeight) }
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
