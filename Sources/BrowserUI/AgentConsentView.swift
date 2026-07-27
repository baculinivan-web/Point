import BrowserAutomation
import BrowserCore
import SwiftUI

/// Asks the person to authorize what the agent is about to do.
///
/// Sits directly above the composer, where their attention already is, and
/// blocks the tool call until they answer — the model cannot proceed past it
/// and cannot dismiss it on its own.
struct AgentConsentCard: View {
    let request: AgentConsentRequest
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: iconName)
                    .foregroundStyle(Color.accentAgent)
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }

            if !request.title.isEmpty {
                Text(request.title)
                    .font(.callout.weight(.medium))
            }

            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !request.origin.isEmpty {
                Label(request.origin, systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(BrowserLocalization.string("agent_consent_deny")) {
                    onDecision(false)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button(approveTitle) {
                    onDecision(true)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thickMaterial)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentAgent.opacity(0.55), lineWidth: 1)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var iconName: String {
        switch request.kind {
        case .browserControl: "hand.raised.fill"
        case .action: "exclamationmark.triangle.fill"
        }
    }

    private var headline: String {
        switch request.kind {
        case .browserControl:
            BrowserLocalization.string("agent_consent_control_headline")
        case .action:
            BrowserLocalization.string("agent_consent_action_headline")
        }
    }

    private var approveTitle: String {
        switch request.kind {
        case .browserControl:
            BrowserLocalization.string("agent_consent_allow_control")
        case .action:
            BrowserLocalization.string("agent_consent_allow_action")
        }
    }
}

/// The live record of what the agent has done, shown while it holds control.
struct AgentStepTicker: View {
    let activity: AgentActivityCenter
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.rays")
                .foregroundStyle(Color.accentAgent)
                .symbolEffect(.pulse, isActive: activity.isActing)

            Text(activity.steps.last?.text
                ?? BrowserLocalization.string("agent_ticker_idle"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Button(BrowserLocalization.string("agent_ticker_stop"), action: onStop)
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background {
            Capsule().fill(.thinMaterial)
            Capsule().strokeBorder(Color.accentAgent.opacity(0.4), lineWidth: 1)
        }
    }
}
