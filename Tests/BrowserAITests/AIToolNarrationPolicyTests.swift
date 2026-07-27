import Foundation
import Testing

@testable import BrowserAI

@Suite("Browser tool narration")
struct AIToolNarrationPolicyTests {
    private func call(_ name: String) -> AIToolCall {
        AIToolCall(id: UUID().uuidString, name: name, arguments: .object([:]))
    }

    @Test("Browser rounds suppress assistant commentary")
    func browserCallsAreSilent() {
        #expect(
            AIChatSession.shouldSuppressToolNarration(
                toolCalls: [call("browser_click")],
                browserControlWasActive: false
            )
        )
        #expect(
            AIChatSession.shouldSuppressToolNarration(
                toolCalls: [call("web_search")],
                browserControlWasActive: true
            )
        )
    }

    @Test("Ordinary tools and final answers retain assistant text")
    func nonBrowserCallsKeepText() {
        #expect(
            !AIChatSession.shouldSuppressToolNarration(
                toolCalls: [call("web_search")],
                browserControlWasActive: false
            )
        )
        #expect(
            !AIChatSession.shouldSuppressToolNarration(
                toolCalls: [],
                browserControlWasActive: true
            )
        )
    }
}
