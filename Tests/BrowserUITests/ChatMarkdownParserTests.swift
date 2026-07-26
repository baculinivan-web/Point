import Testing
@testable import BrowserUI

@Suite("Chat Markdown parsing")
struct ChatMarkdownParserTests {
    private func blocks(_ text: String) -> [ChatMarkdownBlock] {
        ChatMarkdownParser.blocks(from: text)
    }

    @Test func parsesPipeTableWithAlignments() throws {
        let parsed = blocks("""
        | Plan | Price | Limit |
        |:-----|------:|:-----:|
        | Pro  | $20   | 5x    |
        | Max  | $100  | 20x   |
        """)

        #expect(parsed.count == 1)
        guard case let .table(header, rows, alignments) = parsed[0] else {
            Issue.record("expected a table, got \(parsed)")
            return
        }
        #expect(header == ["Plan", "Price", "Limit"])
        #expect(rows == [["Pro", "$20", "5x"], ["Max", "$100", "20x"]])
        #expect(alignments == [.leading, .trailing, .center])
    }

    /// A ragged row must not desynchronise the columns.
    @Test func padsShortRowsToHeaderWidth() throws {
        let parsed = blocks("""
        | A | B | C |
        |---|---|---|
        | 1 |
        """)
        guard case let .table(_, rows, _) = parsed[0] else {
            Issue.record("expected a table")
            return
        }
        #expect(rows == [["1", "", ""]])
    }

    @Test func tableStopsAtFollowingProse() throws {
        let parsed = blocks("""
        | A | B |
        |---|---|
        | 1 | 2 |

        After the table.
        """)
        #expect(parsed.count == 2)
        guard case .table = parsed[0] else {
            Issue.record("expected a table first")
            return
        }
        guard case let .paragraph(text) = parsed[1] else {
            Issue.record("expected a paragraph second")
            return
        }
        #expect(text == "After the table.")
    }

    /// A pipe in ordinary prose must not be read as a table.
    @Test func prosePipesAreNotTables() {
        let parsed = blocks("Use grep | sort to filter output.")
        guard case .paragraph = parsed.first else {
            Issue.record("expected a paragraph, got \(parsed)")
            return
        }
    }

    @Test func parsesHeadingsListsAndCode() throws {
        let parsed = blocks("""
        ## Summary

        - first
        - second

        1. step one
        2. step two

        ```
        let x = 1
        ```

        > quoted line

        ---
        """)

        #expect(parsed.count == 6)
        guard case let .heading(level, text) = parsed[0] else {
            Issue.record("expected heading")
            return
        }
        #expect(level == 2)
        #expect(text == "Summary")

        guard case let .bulletList(bullets) = parsed[1] else {
            Issue.record("expected bullets")
            return
        }
        #expect(bullets == ["first", "second"])

        guard case let .numberedList(numbers) = parsed[2] else {
            Issue.record("expected numbered list")
            return
        }
        #expect(numbers == ["step one", "step two"])

        guard case let .codeBlock(code) = parsed[3] else {
            Issue.record("expected code block")
            return
        }
        #expect(code == "let x = 1")

        guard case let .quote(quote) = parsed[4] else {
            Issue.record("expected quote")
            return
        }
        #expect(quote == "quoted line")

        guard case .divider = parsed[5] else {
            Issue.record("expected divider")
            return
        }
    }

    /// Markdown inside a fence stays literal.
    @Test func codeFenceKeepsMarkdownLiteral() throws {
        let parsed = blocks("""
        ```
        | not | a table |
        # not a heading
        ```
        """)
        #expect(parsed.count == 1)
        guard case let .codeBlock(code) = parsed[0] else {
            Issue.record("expected code block")
            return
        }
        #expect(code.contains("| not | a table |"))
        #expect(code.contains("# not a heading"))
    }

    @Test func plainTextBecomesOneParagraph() throws {
        let parsed = blocks("Just a sentence.\nAnd its continuation.")
        #expect(parsed.count == 1)
        guard case let .paragraph(text) = parsed[0] else {
            Issue.record("expected paragraph")
            return
        }
        #expect(text == "Just a sentence.\nAnd its continuation.")
    }
}
