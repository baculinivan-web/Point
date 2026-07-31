import Foundation

/// How much authority an action needs before the agent may perform it.
public enum AgentActionRisk: Sendable, Equatable {
    /// Reading, navigating, scrolling, clicking inert controls.
    case safe
    /// Irreversible or outward-facing: buying, sending, or deleting.
    case needsConfirmation
    /// The agent never does this, with or without consent — the person does it.
    case blocked(reason: String)

    public static func == (lhs: AgentActionRisk, rhs: AgentActionRisk) -> Bool {
        switch (lhs, rhs) {
        case (.safe, .safe), (.needsConfirmation, .needsConfirmation):
            true
        case (.blocked, .blocked):
            true
        default:
            false
        }
    }
}

/// Decides which page actions the agent may take on its own.
///
/// The rules read the element's own semantics — role, input type, autocomplete
/// hint, accessible name — so they work without a per-site list.
///
/// Tuned to fire on actions a person would actually want to be asked about.
/// The instinct is to err toward asking, but a gate that interrupts on every
/// search box and filter button trains people to approve without reading,
/// which costs more safety than the extra prompts buy.
public struct AgentActionClassifier: Sendable {
    public static let shared = AgentActionClassifier()

    public init() {}

    /// Input kinds the agent must never fill, no matter what was approved.
    private static let blockedInputTypes: Set<String> = ["password", "file"]

    private static let blockedAutocompleteFragments = [
        "cc-number", "cc-csc", "cc-exp", "cc-name", "cc-type",
        "current-password", "new-password", "one-time-code"
    ]

    /// Words that mark a control as genuinely irreversible or outward-facing.
    ///
    /// Kept tight on purpose. An earlier, broader list included things like
    /// "apply", "accept", "book", and "post", which fire on filter buttons,
    /// cookie banners, and half the navigation on a normal site — every one of
    /// those is a confirmation the person has to dismiss, and a gate that
    /// interrupts constantly is a gate people learn to click through.
    /// Both languages the app ships in, matched as whole words.
    private static let confirmationPhrases = [
        // Spending money
        "buy", "buy now", "purchase", "purchase now", "pay", "pay now",
        "place order", "submit order", "confirm payment", "complete purchase",
        "donate", "subscribe", "unsubscribe", "transfer", "withdraw",
        "deposit", "купить", "оплатить", "заказать", "оформить заказ",
        "пожертвовать", "перевести", "вывести", "пополнить",
        "подписаться", "отписаться",
        // Sending things in the person's name
        "send", "publish", "отправить", "опубликовать",
        // Destroying things
        "delete", "deactivate", "удалить", "удаление", "деактивировать"
    ]

    /// Sites where the agent stops and hands control back: it must never drive
    /// an authentication flow with the person's live session.
    private static let authenticationHosts = [
        "accounts.google.com", "login.microsoftonline.com", "appleid.apple.com",
        "idmsa.apple.com", "login.yahoo.com", "oauth.vk.com", "id.vk.com",
        "passport.yandex.ru", "oauth.yandex.ru", "github.com/login",
        "login.live.com", "auth0.com", "okta.com", "id.apple.com"
    ]

    public func risk(for element: AgentElement) -> AgentActionRisk {
        if let blocked = blockedRisk(for: element) { return blocked }

        let directIntent = element.name + " " + element.value
        if AgentPhraseMatcher.matches(
            directIntent,
            anyOf: Self.confirmationPhrases
        ) {
            return .needsConfirmation
        }

        // A vague final button such as "Continue" can still sit in a form
        // whose accessible label or other submit control says "Place order".
        if element.isSubmit,
           AgentPhraseMatcher.matches(
               submissionIntent(for: element),
               anyOf: Self.confirmationPhrases
           ) {
            return .needsConfirmation
        }
        return .safe
    }

    /// Risk of pressing Enter after typing in a field. Enter is navigation for
    /// most forms, not consent to an irreversible act, so it is safe unless the
    /// owning form carries a concrete consequential intent.
    public func submissionRisk(for element: AgentElement) -> AgentActionRisk {
        if let blocked = blockedRisk(for: element) { return blocked }
        if element.isSearchContext { return .safe }
        if AgentPhraseMatcher.matches(
            submissionIntent(for: element),
            anyOf: Self.confirmationPhrases
        ) {
            return .needsConfirmation
        }
        return .safe
    }

    private func blockedRisk(for element: AgentElement) -> AgentActionRisk? {
        if Self.blockedInputTypes.contains(element.inputType) {
            return .blocked(
                reason: element.inputType == "password"
                    ? "password fields"
                    : "file pickers"
            )
        }
        if element.role == "password" || element.role == "file" {
            return .blocked(
                reason: element.role == "password" ? "password fields" : "file pickers"
            )
        }
        let autocomplete = element.autocomplete
        if Self.blockedAutocompleteFragments.contains(where: autocomplete.contains) {
            return .blocked(reason: "payment and credential fields")
        }
        return nil
    }

    /// Typing risk differs from clicking risk: any text going into a credential
    /// or payment field is blocked even when the field itself looks ordinary.
    public func typingRisk(for element: AgentElement) -> AgentActionRisk {
        if let blocked = blockedRisk(for: element) { return blocked }
        // Whole-word matching matters most here: as a substring, "pin" is
        // inside "shipping" and would block typing an address.
        let credentialPhrases = [
            "password", "пароль", "cvv", "cvc", "card number", "номер карты",
            "security code", "код безопасности", "pin code", "пин код",
            "seed phrase", "сид фраза"
        ]
        if AgentPhraseMatcher.matches(
            element.name + " " + element.placeholder,
            anyOf: credentialPhrases
        ) {
            return .blocked(reason: "credential and payment fields")
        }
        return .safe
    }

    private func submissionIntent(for element: AgentElement) -> String {
        [
            element.name,
            element.value,
            element.formAction,
            element.formIntent
        ].joined(separator: " ")
    }

    /// True when a URL is an identity-provider flow the agent must not drive.
    public func isAuthenticationURL(_ url: URL) -> Bool {
        let target = Self.normalize(
            (url.host ?? "") + url.path
        )
        return Self.authenticationHosts.contains { target.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
