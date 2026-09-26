import AppKit
import BrowserAutomation
import BrowserCore
import UserNotifications

@MainActor
enum AgentConsentNotifier {
    static func prepare() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
        }
    }

    static func notify(for request: AgentConsentRequest) {
        NSApp.requestUserAttention(.criticalRequest)

        Task {
            let center = UNUserNotificationCenter.current()
            let allowed = (try? await center.requestAuthorization(
                options: [.alert, .sound]
            )) ?? false
            guard allowed else { return }

            let content = UNMutableNotificationContent()
            content.title = BrowserLocalization.string("agent_notification_title")
            content.body = request.detail.isEmpty ? request.title : request.detail
            content.sound = .default
            try? await center.add(
                UNNotificationRequest(
                    identifier: "point-agent-consent-\(request.id.uuidString)",
                    content: content,
                    trigger: nil
                )
            )
        }
    }
}
