import Foundation
import Testing
@testable import BrowserAI

@Suite("Attachment serialization")
struct AIAttachmentTests {
    private let imageBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])

    private func request(with attachments: [AIAttachment]) -> AIChatRequest {
        AIChatRequest(
            model: "m",
            system: "",
            messages: [.user(text: "what is this?", attachments: attachments)],
            tools: [],
            maxTokens: 100
        )
    }

    @Test func anthropicSendsImageBlocksBeforeText() throws {
        let attachment = AIAttachment(
            kind: .image,
            name: "shot.jpg",
            mediaType: "image/jpeg",
            data: imageBytes
        )
        let body = AnthropicProvider.requestBody(for: request(with: [attachment]))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])

        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "image")
        let source = try #require(blocks[0]["source"] as? [String: Any])
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == imageBytes.base64EncodedString())
        #expect(blocks[1]["type"] as? String == "text")
    }

    @Test func openAISendsDataURLImageParts() throws {
        let attachment = AIAttachment(
            kind: .image,
            name: "shot.jpg",
            mediaType: "image/jpeg",
            data: imageBytes
        )
        let body = OpenAICompatibleProvider.requestBody(for: request(with: [attachment]))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let parts = try #require(messages[0]["content"] as? [[String: Any]])

        #expect(parts[0]["type"] as? String == "text")
        #expect(parts[1]["type"] as? String == "image_url")
        let imageURL = try #require(parts[1]["image_url"] as? [String: Any])
        let url = try #require(imageURL["url"] as? String)
        #expect(url.hasPrefix("data:image/jpeg;base64,"))
    }

    /// Text attachments are inlined so they work on providers without any
    /// document support.
    @Test func textAttachmentsAreInlinedForBothProviders() throws {
        let attachment = AIAttachment(kind: .text, name: "notes.md", text: "hello file")
        let anthropic = AnthropicProvider.requestBody(for: request(with: [attachment]))
        let anthropicMessages = try #require(anthropic["messages"] as? [[String: Any]])
        let blocks = try #require(anthropicMessages[0]["content"] as? [[String: Any]])
        let anthropicText = try #require(blocks[0]["text"] as? String)
        #expect(anthropicText.contains("<attached_file name=\"notes.md\">"))
        #expect(anthropicText.contains("hello file"))
        #expect(anthropicText.hasSuffix("what is this?"))

        let openAI = OpenAICompatibleProvider.requestBody(for: request(with: [attachment]))
        let openAIMessages = try #require(openAI["messages"] as? [[String: Any]])
        let content = try #require(openAIMessages[0]["content"] as? String)
        #expect(content.contains("<attached_file name=\"notes.md\">"))
    }

    @Test func plainMessagesStayScalarWithoutAttachments() throws {
        let body = OpenAICompatibleProvider.requestBody(for: request(with: []))
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "what is this?")
    }

    @Test func attachmentsSurviveARoundTripThroughStorage() throws {
        let original = AIAttachment(
            kind: .image,
            name: "a.jpg",
            mediaType: "image/jpeg",
            data: imageBytes
        )
        let message = AIChatMessage(role: .user, text: "hi", attachments: [original])
        let data = try JSONEncoder().encode(message)
        let restored = try JSONDecoder().decode(AIChatMessage.self, from: data)
        #expect(restored.attachments == [original])
    }

    /// Conversations stored before attachments existed must still decode.
    @Test func legacyStoredMessagesDecodeWithoutAttachments() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","role":"user","text":"hi"}
        """
        let restored = try JSONDecoder().decode(
            AIChatMessage.self,
            from: Data(legacy.utf8)
        )
        #expect(restored.attachments.isEmpty)
        #expect(restored.toolActivities.isEmpty)
        #expect(restored.text == "hi")
    }
}

@Suite("Image capability gate")
struct AIImageCapabilityTests {
    @Test(arguments: [
        "llava:13b", "llama3.2-vision", "qwen2.5vl:7b", "qwen3-vl:8b",
        "moondream", "gemma3:4b", "minicpm-v"
    ])
    func ollamaVisionModelsAreAccepted(name: String) {
        #expect(AIChatSettings.supportsImages(provider: .ollama, model: name))
    }

    @Test(arguments: ["llama3.1:8b", "qwen3:8b", "mistral:7b", "phi4", ""])
    func ollamaTextOnlyModelsAreRejected(name: String) {
        #expect(!AIChatSettings.supportsImages(provider: .ollama, model: name))
    }

    @Test func hostedProvidersAlwaysAllowImages() {
        #expect(AIChatSettings.supportsImages(provider: .anthropic, model: ""))
        #expect(AIChatSettings.supportsImages(provider: .openAICompatible, model: ""))
    }
}
