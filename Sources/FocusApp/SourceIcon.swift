import SwiftUI
import FocusCore

/// A small drawn mark for where an item came from, in each brand's colors. Drawn
/// rather than bundled so no logo files ship with the app.
struct SourceIcon: View {
    let source: ItemSource
    var size: CGFloat = 16

    var body: some View {
        switch source {
        case .slack: SlackMark().frame(width: size, height: size)
        case .jira: JiraMark().frame(width: size, height: size)
        case .idea:
            Image(systemName: "lightbulb.fill")
                .font(.system(size: size * 0.8))
                .foregroundStyle(Color(hue: 0.13, saturation: 0.8, brightness: 0.95))
                .frame(width: size, height: size)
        }
    }
}

/// Slack's pinwheel: four rounded bars, one per brand color, each with a dot.
private struct SlackMark: View {
    var body: some View {
        GeometryReader { g in
            let u = g.size.width / 6
            ZStack {
                bar(Color(red: 0.21, green: 0.77, blue: 0.94), u, x: 2.5, y: 1.5, vertical: true)    // blue
                bar(Color(red: 0.18, green: 0.71, blue: 0.49), u, x: 4.5, y: 2.5, vertical: false)   // green
                bar(Color(red: 0.93, green: 0.70, blue: 0.18), u, x: 3.5, y: 4.5, vertical: true)    // yellow
                bar(Color(red: 0.88, green: 0.12, blue: 0.35), u, x: 1.5, y: 3.5, vertical: false)   // red
            }
        }
    }

    private func bar(_ c: Color, _ u: CGFloat, x: CGFloat, y: CGFloat, vertical: Bool) -> some View {
        Capsule().fill(c)
            .frame(width: vertical ? u : u * 3, height: vertical ? u * 3 : u)
            .position(x: x * u, y: y * u)
    }
}

/// Jira's mark: two stacked chevrons in Atlassian blue.
private struct JiraMark: View {
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack {
                chevron(s).fill(Color(red: 0.15, green: 0.52, blue: 1.0)).offset(x: -s * 0.12)
                chevron(s).fill(Color(red: 0.0, green: 0.32, blue: 0.80)).offset(x: s * 0.12)
            }
        }
    }

    /// A diamond missing its left point, which reads as the Jira arrow at small sizes.
    private func chevron(_ s: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: s * 0.5, y: s * 0.12))
            p.addLine(to: CGPoint(x: s * 0.88, y: s * 0.5))
            p.addLine(to: CGPoint(x: s * 0.5, y: s * 0.88))
            p.addLine(to: CGPoint(x: s * 0.36, y: s * 0.74))
            p.addLine(to: CGPoint(x: s * 0.6, y: s * 0.5))
            p.addLine(to: CGPoint(x: s * 0.36, y: s * 0.26))
            p.closeSubpath()
        }
    }
}
