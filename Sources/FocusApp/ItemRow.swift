import SwiftUI
import FocusCore

/// The two parts of a row for the newer styles: who (or the ticket key) and what.
struct RowParts {
    let who: String
    let tag: String?
    let body: String?

    init(_ item: Item, hideText: Bool) {
        switch item.source {
        case .slack:
            // Titles are "Ann: text" or "Ann in #ch: text".
            if let r = item.title.range(of: ": ") {
                who = String(item.title[..<r.lowerBound])
                body = hideText ? nil : String(item.title[r.upperBound...])
            } else {
                who = item.title
                body = nil
            }
            // Small kind tag; a plain 1:1 DM needs none (the Slack icon and name say it).
            tag = item.detail.hasPrefix("group DM") ? "group"
                : item.detail.hasPrefix("thread") ? "thread"
                : item.detail.hasPrefix("mention") ? "mention" : nil
        case .jira:
            // Detail is "KEY" or "KEY · waiting on you" / "KEY · Ann mentioned you".
            let bits = item.detail.components(separatedBy: " · ")
            who = bits.first ?? item.detail
            tag = bits.count > 1 ? bits.dropFirst().joined(separator: " · ") : nil
            body = item.title
        case .idea:
            who = item.title
            tag = nil
            body = nil
        }
    }
}

/// Short time for the right edge: "35m" / "3h" for today, then the day it happened
/// ("Thu", or "Dec 29" if older than a week); a deadline countdown; or when a boomerang
/// returns. Color carries the urgency. The full wording is in the row's tooltip.
func shortAge(_ item: Item, scale: AgeScale, now: Date) -> String {
    if let until = item.snoozedUntil {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(until, inSameDayAs: now) ? "jmm" : "EEEjmm")
        return "↩︎ " + f.string(from: until)
    }
    if let due = item.dueAt { return Deadline.countdown(to: due, now: now) }
    if item.source == .idea || item.removed { return "" }
    // When it started: the first unanswered message/mention, or my last Jira comment.
    guard let since = item.waitingSince ?? item.lastMyResponse else { return "new" }
    let cal = Calendar.current
    if cal.isDate(since, inSameDayAs: now) {
        let mins = Int(now.timeIntervalSince(since) / 60)
        return mins < 60 ? "\(max(mins, 0))m" : "\(mins / 60)h"
    }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate(now.timeIntervalSince(since) < 6 * 86_400 ? "EEE" : "MMMd")
    return f.string(from: since)
}

/// One queue row (Liquid Glass look): click opens, hover actions, highlight, farewell
/// labels, shake.
struct ItemRow: View {
    let item: Item
    let band: AgeScale.Band
    let short: String
    let tooltip: String
    let contentOpacity: Double
    let shakeToken: Int
    let highlighted: Bool
    let closing: QueueModel.ClosingPhase?
    let textScale: Double
    let hideText: Bool
    let onSkip: () -> Void
    let onDismiss: () -> Void
    let onDone: () -> Void
    let onBoomerang: () -> Void
    let onOpen: (URL) -> Void
    /// Called after a task expands, so the panel can scroll it fully into view.
    var onExpanded: () -> Void = {}
    @State private var hovering = false
    @State private var sweep: CGFloat = -1
    /// Tasks have nowhere else to read them, so a click shows the whole text.
    @State private var expanded = false

    private var color: Color { Self.rowColor(band: band, closing: closing, removed: item.removed) }

    /// Row color for a band and state.
    static func rowColor(band: AgeScale.Band, closing: QueueModel.ClosingPhase?, removed: Bool) -> Color {
        switch closing {
        case .label(.closed): return Color(hue: 0.36, saturation: 0.8, brightness: 0.75)      // closed: green
        case .label(.responded): return Color(hue: 0.6, saturation: 0.85, brightness: 0.9)   // responded: blue
        case .label(.removed): return Color(white: 0.55)                                      // removed: grey
        case .current: return bandColor(band)   // every exit starts in the item's own color
        case nil: break
        }
        if removed { return Color(white: 0.55) }
        return bandColor(band)
    }

    /// Amber (hue 0.11) at the start of the ramp, red (0) at the end.
    static func rampHue(_ f: Double) -> Double { 0.11 * (1 - min(max(f, 0), 1)) }

    static func bandColor(_ band: AgeScale.Band) -> Color {
        switch band {
        case .none: Color(hue: 0.6, saturation: 0.7, brightness: 0.9)   // tasks: blue
        case .green: Color(hue: 0.33, saturation: 0.75, brightness: 0.8)
        // Past "green until": starts at a clear amber (never green) and deepens to red.
        case .ramp(let f): Color(hue: rampHue(f), saturation: 0.85, brightness: 0.9)
        case .red: Color(hue: 0.0, saturation: 0.85, brightness: 0.9)
        // Timed items: blue -> purple -> red over the last third.
        case .due(let f): Color(hue: 0.6 + 0.4 * f, saturation: 0.75, brightness: 0.9)
        }
    }
    private var quiet: Bool { (item.removed || item.snoozedUntil != nil) && closing == nil }

    var body: some View {
        let lit = highlighted || closing != nil
        let rowOpacity = lit ? 1.0 : contentOpacity
        let parts = RowParts(item, hideText: hideText)

        Button {
            if let url = item.url { onOpen(url) }
            else if item.source == .idea {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                if expanded { onExpanded() }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Everything fades with the panel; a lit row (an alert) stays at full strength.
                ageMark
                    .opacity(rowOpacity)
                SourceIcon(source: item.source, size: iconSize)
                    .opacity(rowOpacity * (quiet ? 0.5 : 1))
                    .padding(.top, 1)
                content(parts)
                    .opacity(rowOpacity * (quiet ? 0.6 : 1))
                Spacer(minLength: 4)
                trailing
                    .opacity(rowOpacity * (quiet ? 0.6 : 1))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.source == .idea ? "\(item.title)\n\(tooltip)\nClick to show all" : tooltip)
        .background { background(lit: lit, rowOpacity: rowOpacity) }
        // Actions float over the right edge instead of pushing the text aside.
        .overlay(alignment: .trailing) {
            if hovering { actions.padding(.trailing, 6).transition(.opacity) }
        }
        .overlay { if lit { litOverlay } }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .animation(.easeInOut(duration: 0.4), value: highlighted)
        .animation(.easeInOut(duration: 0.4), value: closing)
        .onHover { hovering = $0 }
        .modifier(Shake(animatableData: CGFloat(shakeToken)))
    }

    private var iconSize: CGFloat {
        20 * textScale
    }

    /// Age: a thin colored edge.
    private var ageMark: some View {
        Capsule().fill(color).frame(width: 3).frame(maxHeight: .infinity)
    }

    private func content(_ p: RowParts) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Tasks wrap to two lines, and show everything when clicked.
                Text(p.who).font(.system(size: 13 * textScale, weight: .semibold))
                    .lineLimit(item.source == .idea ? (expanded ? nil : 2) : 1)
                    .fixedSize(horizontal: false, vertical: item.source == .idea)
                if let tag = p.tag { tagPill(tag) }
            }
            if let body = p.body {
                Text(body).font(.system(size: 12.5 * textScale)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    /// A small kind pill (group / thread / mention, or Jira's "waiting on you"). It keeps its
    /// size and the name truncates instead, so a long channel name can't squeeze it out.
    private func tagPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10 * textScale, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
            .fixedSize()
            .layoutPriority(2)
    }

    @ViewBuilder private var trailing: some View {
        if item.removed && closing == nil {
            capsule("REMOVED", size: 9)
        } else if !short.isEmpty {
            Text(short)
                .font(.system(size: 11 * textScale, weight: .medium).monospacedDigit())
                .foregroundStyle(band == .red && item.snoozedUntil == nil ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if item.removed {
                iconButton("xmark", "Clear: it's no longer in your sprint. It comes back if it returns and needs a response.", onDismiss)
            } else {
                iconButton("clock.arrow.circlepath", item.snoozedUntil == nil
                           ? "Boomerang: move to the bottom; it comes back in a few business hours, or sooner if something new happens"
                           : "Bring it back now", onBoomerang)
                iconButton("arrow.uturn.down", "Skip: send to the back", onSkip)
                if item.source == .idea {
                    iconButton("checkmark", "Done: delete (you can undo for a few seconds)", onDone)
                } else {
                    iconButton("xmark", "Dismiss until something new happens", onDismiss)
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11 * textScale, weight: .semibold))
                .frame(width: 22, height: 22).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func background(lit: Bool, rowOpacity: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return ZStack {
            // Solid backing so a lit row reads clearly over whatever is behind the panel.
            shape.fill(.regularMaterial).opacity(lit ? 1 : 0)
            shape.fill(lit ? color.opacity(0.3) : Color.primary.opacity(hovering ? 0.08 : 0)).opacity(rowOpacity)
        }
    }

    @ViewBuilder private var litOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        shape.strokeBorder(color, lineWidth: 1.5)
        if case .label(let kind) = closing {
            capsule(kind == .closed ? "CLOSED" : kind == .responded ? "RESPONDED" : "REMOVED", size: 15)
                .transition(.scale.combined(with: .opacity))
        }
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.35)
                .offset(x: sweep * geo.size.width)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .onAppear {
            sweep = -0.4
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: false)) { sweep = 1.1 }
        }
        .onDisappear { sweep = -0.4 }
    }

    private func capsule(_ text: String, size: Double) -> some View {
        Text(text)
            .font(.system(size: size * textScale, weight: .heavy))
            .tracking(size > 12 ? 3 : 1.2)
            .foregroundStyle(.white)
            .padding(.horizontal, size > 12 ? 10 : 6).padding(.vertical, size > 12 ? 3 : 2)
            .background(Capsule().fill(color))
    }
}

/// The panel's background: macOS 26 Liquid Glass, or a thin material on older systems.
struct PanelBackground: View {
    let opacity: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape).opacity(opacity)
        } else {
            shape.fill(.ultraThinMaterial).opacity(opacity)
        }
    }
}
