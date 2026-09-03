import SwiftUI

/// Renders one session's activity glyph: in its sidebar row, and as the
/// heading glyph of the Agent Dashboard's sections. Pulled out into its own
/// view — rather than inlined in `SessionRowView` as a plain `Image` the
/// way it used to be — specifically so it can own its `pulsing` `@State`
/// itself. If that state lived on `SessionRowView` instead, it would be
/// shared across every activity this row ever shows: a `.blocked` pulse that
/// was mid-cycle when the state cleared (agent got unblocked) and then came
/// back later (blocked again) could resume from whatever phase the old
/// animation left `pulsing` in, or — worse — a `repeatForever` animation
/// started for an earlier `.blocked` value could keep silently running
/// against a view that no longer shows it. Giving this its own small view
/// means SwiftUI tears down and recreates its `@State` fresh every time the
/// row starts showing an indicator again, so the animation always restarts
/// cleanly from the beginning and never lingers past the activity it was
/// animating.
struct SessionActivityIndicator: View {
    let activity: SessionActivity

    /// Reduce Motion must suppress the pulse entirely, not just slow it
    /// down or tone it back — a repeating opacity animation firing every
    /// ~1.1s indefinitely is exactly the kind of motion that accessibility
    /// setting exists to eliminate for users who find it distracting or
    /// disorienting. When it's on, `.blocked` still gets its larger
    /// exclamation-mark glyph (that's a static shape change, not motion),
    /// just rendered at a constant full opacity.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Image(systemName: activity.symbolName)
            .font(.system(size: activity.pointSize))
            .foregroundStyle(activity.tint)
            .opacity(currentOpacity)
            .accessibilityLabel(activity.accessibilityLabel)
            .onAppear {
                // Only `.blocked` pulses — `.yourTurn` stays a small static
                // dot at full opacity always, so there's nothing to animate
                // or to gate on Reduce Motion for that case.
                guard activity == .blocked, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }

    /// `.yourTurn` and a Reduce-Motion `.blocked` both render at a constant
    /// full opacity; a motion-enabled `.blocked` alternates between full
    /// opacity and 0.45 as `pulsing` toggles, driven by the `withAnimation`
    /// call in `onAppear` above.
    private var currentOpacity: Double {
        guard activity == .blocked, !reduceMotion else { return 1.0 }
        return pulsing ? 1.0 : 0.45
    }
}

/// Colour + symbol + size + wording + accessibility mapping for the activity
/// indicator and the dashboard's urgency sections — the single place all of
/// that visual mapping lives, so `SessionActivityIndicator` above and
/// `AgentDashboardView` never hardcode a per-case choice themselves and the
/// two states can never drift apart from what's documented here. Lives in
/// this SwiftUI file (not in SessionActivity.swift) because that file is
/// deliberately Foundation-only/SwiftUI-free so it stays trivially
/// unit-testable.
extension SessionActivity {
    // These exact RGB values are deliberate, not arbitrary: they match
    // the user's existing iTerm2 tab-colour script, so the two tools
    // signal the same states with the same colours.
    var tint: Color {
        switch self {
        case .yourTurn: return Color(red: 210 / 255, green: 158 / 255, blue: 90 / 255)
        case .blocked: return Color(red: 200 / 255, green: 50 / 255, blue: 50 / 255)
        }
    }

    /// `.blocked` deliberately gets a DIFFERENT SHAPE, not just a different
    /// colour: a small filled circle differing only in hue from `.yourTurn`
    /// failed two ways at once — it read as no real escalation between "your
    /// move whenever" and "actively burning time waiting on you," and it was
    /// invisible as a distinction to anyone with colour-vision deficiency.
    /// The exclamation mark is a shape change everyone can read regardless of
    /// colour perception, on top of (not instead of) the colour and the pulse
    /// `SessionActivityIndicator` layers on for `.blocked`.
    var symbolName: String {
        switch self {
        case .yourTurn: return "circle.fill"
        case .blocked: return "exclamationmark.circle.fill"
        }
    }

    /// `.blocked` also renders larger (11pt vs. 7pt) for the same reason its
    /// symbol changed: size is a second, colour-independent channel carrying
    /// the same "this one is more urgent" signal.
    var pointSize: CGFloat {
        switch self {
        case .yourTurn: return 7
        case .blocked: return 11
        }
    }

    /// The state's human name — the dashboard's section headings and the
    /// indicator's accessibility label say it the same way.
    var title: String {
        switch self {
        case .yourTurn: return "Waiting for you"
        case .blocked: return "Blocked on you"
        }
    }

    var accessibilityLabel: String { title }
}
