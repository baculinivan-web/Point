import BrowserAutomation
import BrowserCore
import SwiftUI

/// The blue halo that frames the page while the assistant is driving it, plus
/// the markers showing where it just acted.
///
/// Drawn natively above the web view rather than injected into the page: the
/// site must not be able to detect, restyle, or fake the indicator, and it must
/// not appear in the screenshots that go back to the model.
struct AgentControlOverlay: View {
    let activity: AgentActivityCenter
    let tabID: TabID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Flipped once to start the breathing loop; the repeating animation is
    /// attached to this value, so it has to actually change to kick off.
    @State private var isBreathing = false

    private var isControlled: Bool { activity.controlledTabID == tabID }

    var body: some View {
        ZStack {
            if isControlled {
                glow
                GeometryReader { proxy in
                    ForEach(activity.events) { event in
                        marker(for: event, in: proxy.size)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.35), value: isControlled)
        .onChange(of: isControlled, initial: true) { _, controlled in
            isBreathing = controlled && !reduceMotion
        }
    }

    /// A soft inner rim rather than a hard border: it has to read as "something
    /// else is in control here" without covering page content near the edges.
    private var glow: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentAgent.opacity(0.9), lineWidth: 2)
                .blur(radius: 0.5)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentAgent.opacity(0.6), lineWidth: 16)
                .blur(radius: 14)
                .padding(-2)
        }
        .compositingGroup()
        .opacity(isBreathing ? peakOpacity : restOpacity)
        // Attached to `isBreathing`, which flips exactly once: that starts the
        // repeating loop and lets it keep running, which an animation keyed on
        // a derived value never does.
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(duration: activity.isActing ? 0.85 : 1.9)
                    .repeatForever(autoreverses: true),
            value: isBreathing
        )
        .transition(.opacity)
    }

    /// Breathes hard while a step is in flight and idles slowly between them,
    /// so the person can tell at a glance whether the agent is mid-action.
    private var peakOpacity: Double { activity.isActing ? 1.0 : 0.7 }

    private var restOpacity: Double { activity.isActing ? 0.45 : 0.3 }

    @ViewBuilder
    private func marker(for event: AgentVisualEvent, in size: CGSize) -> some View {
        let point = CGPoint(x: event.x * size.width, y: event.y * size.height)

        switch event.kind {
        case .click:
            AgentClickRipple()
                .position(point)
        case .type:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.accentAgent, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.accentAgent.opacity(0.14))
                )
                .frame(
                    width: max(24, event.width * size.width),
                    height: max(18, event.height * size.height)
                )
                .position(point)
                .transition(.opacity)
        case .scroll:
            AgentScrollTrail()
                .position(point)
        }
    }
}

/// An agent click: the press itself, then waves rolling out of it.
///
/// Loud on purpose. This is the one moment where software acts on the person's
/// behalf inside their own logged-in session, and it has to be impossible to
/// miss on a busy page.
private struct AgentClickRipple: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    @State private var waveProgress: Double = 0

    /// Each wave starts a beat after the one before it.
    private static let waveDelays: [Double] = [0, 0.13, 0.26]

    var body: some View {
        ZStack {
            ForEach(Array(Self.waveDelays.enumerated()), id: \.offset) { index, delay in
                Circle()
                    .stroke(Color.accentAgent, lineWidth: 3 - Double(index) * 0.6)
                    .frame(width: waveSize(delay), height: waveSize(delay))
                    .opacity(waveOpacity(delay))
            }

            // The halo under the dot lifts it off light and dark pages alike.
            Circle()
                .fill(Color.accentAgent.opacity(0.35))
                .frame(width: 34, height: 34)
                .blur(radius: 6)

            Circle()
                .fill(Color.accentAgent)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2)
                }
                .frame(width: 20, height: 20)
                .scaleEffect(isPressed ? 0.55 : 1)
                .shadow(color: Color.accentAgent.opacity(0.9), radius: 8)
        }
        .onAppear(perform: animate)
    }

    /// Presses in fast, releases with a small overshoot, and lets the waves
    /// run out behind it.
    private func animate() {
        guard !reduceMotion else {
            waveProgress = 1
            return
        }
        withAnimation(.easeIn(duration: 0.09)) { isPressed = true }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.45).delay(0.09)) {
            isPressed = false
        }
        withAnimation(.easeOut(duration: 0.95)) { waveProgress = 1 }
    }

    /// Waves are staggered by shifting each one's slice of the same progress,
    /// so a single animation drives all three.
    private func phase(_ delay: Double) -> Double {
        min(1, max(0, (waveProgress - delay) / (1 - delay)))
    }

    private func waveSize(_ delay: Double) -> Double {
        18 + phase(delay) * 76
    }

    private func waveOpacity(_ delay: Double) -> Double {
        let phase = phase(delay)
        guard phase > 0 else { return 0 }
        return (1 - phase) * 0.9
    }
}

private struct AgentScrollTrail: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSettled = false

    var body: some View {
        Capsule()
            .fill(Color.accentAgent.opacity(0.35))
            .frame(width: 5, height: isSettled ? 12 : 54)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.5)) { isSettled = true }
            }
    }
}

extension Color {
    /// One blue for every agent affordance — glow, markers, tab badge — so the
    /// colour itself reads as "the assistant is doing this".
    static let accentAgent = Color(
        .sRGB, red: 0.20, green: 0.55, blue: 1.0, opacity: 1
    )
}
