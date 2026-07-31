import Foundation

/// One interactive element the agent can address, as seen by the page script.
///
/// Geometry is viewport-relative CSS pixels; the driver converts it to view
/// points when it aims a real click.
public struct AgentElement: Codable, Sendable, Equatable {
    public var ref: String
    public var role: String
    public var name: String
    public var value: String
    public var placeholder: String
    public var inputType: String
    public var autocomplete: String
    public var href: String
    public var formAction: String
    /// Accessible labels and submit-control text from the owning form. This
    /// lets an Enter press inherit the form's intent (for example "Pay now")
    /// without treating every form submission as consequential.
    public var formIntent: String
    public var isSubmit: Bool
    /// True when the control belongs to a search form. Submitting a search is
    /// not an irreversible act and must not be gated like one.
    public var isSearchContext: Bool
    public var hasDownload: Bool
    public var disabled: Bool
    public var checked: Bool
    public var inViewport: Bool
    public var inFrame: Bool
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
}

/// What the page looks like right now, in the form the model reads.
public struct AgentPageSnapshot: Codable, Sendable, Equatable {
    public var url: String
    public var title: String
    public var scrollY: Double
    public var scrollHeight: Double
    public var viewportHeight: Double
    public var readyState: String
    public var text: String
    public var blockedFrames: [String]
    public var elements: [AgentElement]

    /// Renders the snapshot as the compact listing handed to the model.
    ///
    /// Page text is fenced in a tag that names it untrusted, because this is
    /// the exact channel a prompt-injection attempt arrives through.
    public func rendered(classifier: AgentActionClassifier = .shared) -> String {
        var lines: [String] = []
        lines.append("url: \(url)")
        if !title.isEmpty { lines.append("title: \(title)") }

        let bottom = scrollY + viewportHeight
        let remaining = max(0, scrollHeight - bottom)
        lines.append(
            "scroll: \(Int(scrollY))/\(Int(max(0, scrollHeight - viewportHeight)))"
                + (remaining > 4 ? " (more content below)" : " (at the end)")
        )
        if readyState != "complete" {
            lines.append("note: the page is still loading (\(readyState))")
        }
        if !blockedFrames.isEmpty {
            lines.append(
                "note: \(blockedFrames.count) cross-origin frame(s) cannot be "
                    + "inspected or clicked: \(blockedFrames.joined(separator: ", "))"
            )
        }

        lines.append("")
        lines.append("interactive elements:")
        if elements.isEmpty {
            lines.append("  (none found)")
        }
        for element in elements {
            lines.append("  " + line(for: element, classifier: classifier))
        }

        if !text.isEmpty {
            lines.append("")
            lines.append("<untrusted_page_text>")
            lines.append(text)
            lines.append("</untrusted_page_text>")
        }
        return lines.joined(separator: "\n")
    }

    private func line(
        for element: AgentElement,
        classifier: AgentActionClassifier
    ) -> String {
        var parts = ["[\(element.ref)]", element.role]
        if !element.name.isEmpty {
            parts.append("\"\(element.name)\"")
        }
        if !element.value.isEmpty {
            parts.append("value=\"\(element.value)\"")
        } else if !element.placeholder.isEmpty {
            parts.append("placeholder=\"\(element.placeholder)\"")
        }
        if element.role == "checkbox" || element.role == "radio" {
            parts.append(element.checked ? "checked" : "unchecked")
        }
        if element.disabled { parts.append("disabled") }
        if !element.inViewport { parts.append("offscreen") }
        if element.inFrame { parts.append("in-frame") }

        switch classifier.risk(for: element) {
        case .safe:
            break
        case .needsConfirmation:
            parts.append("⚠needs-confirmation")
        case .blocked:
            parts.append("⛔blocked-for-the-person-only")
        }
        return parts.joined(separator: " ")
    }
}
