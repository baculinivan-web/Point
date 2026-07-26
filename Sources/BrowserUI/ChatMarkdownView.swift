import SwiftUI

/// Column alignment declared by a table's delimiter row.
enum ChatTableAlignment: Equatable {
    case leading
    case center
    case trailing

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// A block of assistant output. SwiftUI's Markdown support is inline-only, so
/// block structure — tables above all — is parsed here and laid out natively.
enum ChatMarkdownBlock: Identifiable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bulletList([String])
    case numberedList([String])
    case codeBlock(String)
    case quote(String)
    case table(header: [String], rows: [[String]], alignments: [ChatTableAlignment])
    case divider

    var id: String {
        switch self {
        case let .paragraph(text): "p:\(text.hashValue)"
        case let .heading(level, text): "h\(level):\(text.hashValue)"
        case let .bulletList(items): "ul:\(items.joined().hashValue)"
        case let .numberedList(items): "ol:\(items.joined().hashValue)"
        case let .codeBlock(text): "code:\(text.hashValue)"
        case let .quote(text): "q:\(text.hashValue)"
        case let .table(header, rows, _):
            "t:\(header.joined().hashValue):\(rows.count)"
        case .divider: "hr"
        }
    }
}

enum ChatMarkdownParser {
    /// Line-oriented parse covering what chat models actually emit: tables,
    /// headings, lists, fenced code, quotes, rules, and paragraphs.
    static func blocks(from text: String) -> [ChatMarkdownBlock] {
        var blocks: [ChatMarkdownBlock] = []
        var paragraph: [String] = []
        let lines = text.components(separatedBy: .newlines)
        var index = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                index += 1
                var code: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.codeBlock(code.joined(separator: "\n")))
                continue
            }

            if isTableDelimiter(nextLine(lines, after: index)), isTableRow(trimmed) {
                flushParagraph()
                let header = cells(in: trimmed)
                let alignments = alignments(in: nextLine(lines, after: index) ?? "")
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isTableRow(candidate) else { break }
                    rows.append(normalize(cells(in: candidate), to: header.count))
                    index += 1
                }
                blocks.append(
                    .table(
                        header: header,
                        rows: rows,
                        alignments: normalize(alignments, to: header.count, filler: .leading)
                    )
                )
                continue
            }

            if let level = headingLevel(trimmed) {
                flushParagraph()
                let content = trimmed
                    .drop { $0 == "#" }
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: content))
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if bulletContent(trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count,
                      let item = bulletContent(
                          lines[index].trimmingCharacters(in: .whitespaces)
                      ) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            if numberedContent(trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count,
                      let item = numberedContent(
                          lines[index].trimmingCharacters(in: .whitespaces)
                      ) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let content = lines[index]
                        .trimmingCharacters(in: .whitespaces)
                        .dropFirst()
                        .trimmingCharacters(in: .whitespaces)
                    quoted.append(content)
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func nextLine(_ lines: [String], after index: Int) -> String? {
        let next = index + 1
        guard next < lines.count else { return nil }
        return lines[next].trimmingCharacters(in: .whitespaces)
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && line.hasPrefix("|")
    }

    /// The `|---|:--:|` row that turns the preceding line into a header.
    private static func isTableDelimiter(_ line: String?) -> Bool {
        guard let line, line.contains("|"), line.contains("-") else { return false }
        let body = line.filter { !" |".contains($0) }
        return !body.isEmpty && body.allSatisfy { $0 == "-" || $0 == ":" }
    }

    private static func cells(in row: String) -> [String] {
        var trimmed = row
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func alignments(in delimiter: String) -> [ChatTableAlignment] {
        cells(in: delimiter).map { cell in
            let hasLeading = cell.hasPrefix(":")
            let hasTrailing = cell.hasSuffix(":")
            if hasLeading && hasTrailing { return .center }
            if hasTrailing { return .trailing }
            return .leading
        }
    }

    private static func normalize(_ row: [String], to count: Int) -> [String] {
        normalize(row, to: count, filler: "")
    }

    private static func normalize<T>(_ row: [T], to count: Int, filler: T) -> [T] {
        if row.count == count { return row }
        if row.count > count { return Array(row.prefix(count)) }
        return row + Array(repeating: filler, count: count - row.count)
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else {
            return nil
        }
        return hashes
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" }
    }

    private static func bulletContent(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedContent(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }
}

/// Renders parsed Markdown, keeping inline styling and links intact.
struct ChatMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ChatMarkdownParser.blocks(from: text)) { block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: ChatMarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            inlineText(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .heading(level, text):
            inlineText(text)
                .font(.system(size: headingSize(level), weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", content: item)
                }
            }
        case let .numberedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(marker: "\(index + 1).", content: item)
                }
            }
        case let .codeBlock(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(9)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                inlineText(text)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .table(header, rows, alignments):
            ChatMarkdownTable(header: header, rows: rows, alignments: alignments)
        case .divider:
            Divider()
        }
    }

    private func listRow(marker: String, content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(marker)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            inlineText(content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineText(_ text: String) -> some View {
        Text(Self.inlineAttributed(text))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 17
        case 2: 15.5
        default: 14
        }
    }

    static func inlineAttributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
    }
}

/// A Markdown table. Wide tables scroll horizontally rather than squeezing the
/// panel, which matters at narrow panel widths.
private struct ChatMarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let alignments: [ChatTableAlignment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                        cellView(cell, index: index, isHeader: true)
                    }
                }
                .background(Color.primary.opacity(0.06))

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    Divider()
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            cellView(cell, index: index, isHeader: false)
                        }
                    }
                    .background(
                        rowIndex.isMultiple(of: 2)
                            ? Color.clear
                            : Color.primary.opacity(0.025)
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.separator.opacity(0.7), lineWidth: 1)
            }
            .padding(.vertical, 2)
        }
    }

    private func cellView(_ cell: String, index: Int, isHeader: Bool) -> some View {
        let alignment = index < alignments.count ? alignments[index] : .leading
        return Text(ChatMarkdownView.inlineAttributed(cell))
            .font(isHeader ? .caption.weight(.semibold) : .caption)
            .multilineTextAlignment(alignment.textAlignment)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(minWidth: 44, maxWidth: 320, alignment: alignment.frameAlignment)
    }
}
