import Foundation

/// Matches control labels against a word list.
///
/// Deliberately not a substring search. `"Facebook".contains("book")`,
/// `"Shipping address".contains("pin")`, and `"Postal code".contains("post")`
/// are all true, and each one turns an ordinary control into a confirmation
/// prompt — or, worse, blocks typing into a perfectly safe field.
///
/// Matching is on whole words, and only whole words. Prefix matching was the
/// obvious way to cover a word's inflections with one entry, but it trades one
/// class of false positive for another: `send` reaches `Sender name`, `deposit`
/// reaches `Depositions`, and in Russian `удал` reaches `удалённый` — remote,
/// not deleted. Listing the forms that actually appear on buttons is longer
/// but says exactly what it does.
enum AgentPhraseMatcher {
    static func matches(_ text: String, anyOf phrases: [String]) -> Bool {
        let tokens = self.tokens(in: text)
        guard !tokens.isEmpty else { return false }
        return phrases.contains { phrase in
            matches(tokens: tokens, phrase: phrase)
        }
    }

    private static func matches(tokens: [String], phrase: String) -> Bool {
        let wanted = self.tokens(in: phrase)
        guard !wanted.isEmpty, tokens.count >= wanted.count else { return false }

        // A multi-word phrase has to appear as consecutive words, so
        // "place order" does not fire on "place your first order".
        for start in 0...(tokens.count - wanted.count)
        where Array(tokens[start..<(start + wanted.count)]) == wanted {
            return true
        }
        return false
    }

    /// Lowercased, diacritic-folded words. Punctuation and digits separate
    /// words, so `Delete/Remove` and `Buy—now` both split correctly.
    static func tokens(in text: String) -> [String] {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
