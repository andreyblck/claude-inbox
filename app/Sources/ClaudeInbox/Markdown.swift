import SwiftUI

/// Enough markdown to read an answer in.
///
/// SwiftUI's own `AttributedString(markdown:)` handles emphasis and links and
/// stops there: a fenced block arrives with its backticks, a list with its
/// dashes, and a table as a wall of pipes. Those are exactly the shapes these
/// answers are written in, so a panel that cannot render them is a panel you
/// leave to go and read the terminal — which is the whole thing this app is for.
enum Markdown {
    enum Block: Identifiable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(language: String?, text: String)
        case list(items: [String], ordered: Bool)
        case quote(String)
        case table(header: [String], rows: [[String]])
        case rule

        var id: String {
            switch self {
            case .heading(let level, let text): "h\(level):\(text)"
            case .paragraph(let text): "p:\(text.prefix(48))\(text.count)"
            case .code(_, let text): "c:\(text.prefix(48))\(text.count)"
            case .list(let items, let ordered): "l\(ordered):\(items.count):\(items.first ?? "")"
            case .quote(let text): "q:\(text.prefix(48))"
            case .table(let header, let rows): "t:\(header.joined()):\(rows.count)"
            case .rule: "rule"
            }
        }
    }

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code. Unterminated fences happen when a turn is still being
            // written, so running off the end closes the block rather than losing it.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    text: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if trimmed.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            if let hashes = trimmed.range(of: "^#{1,6} ", options: .regularExpression) {
                flushParagraph()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes.upperBound) - 1
                blocks.append(.heading(level: level, text: String(trimmed[hashes.upperBound...])))
                i += 1
                continue
            }

            // A table is a pipe row followed by a divider row. Without the
            // divider it is just a sentence with pipes in it.
            if trimmed.hasPrefix("|"), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces)
                   .range(of: "^\\|[\\s:|-]+\\|$", options: .regularExpression) != nil
            {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                var body: [String] = []
                while i < lines.count {
                    let quoted = lines[i].trimmingCharacters(in: .whitespaces)
                    guard quoted.hasPrefix(">") else { break }
                    body.append(String(quoted.dropFirst().trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.quote(body.joined(separator: " ")))
                continue
            }

            if trimmed.range(of: "^([-*+] |\\d+[.)] )", options: .regularExpression) != nil {
                flushParagraph()
                var items: [String] = []
                let ordered = trimmed.range(of: "^\\d", options: .regularExpression) != nil
                while i < lines.count {
                    let item = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let marker = item.range(of: "^([-*+] |\\d+[.)] )", options: .regularExpression)
                    else { break }
                    items.append(String(item[marker.upperBound...]))
                    i += 1
                }
                blocks.append(.list(items: items, ordered: ordered))
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func cells(_ row: String) -> [String] {
        var text = row
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Emphasis, code spans and links, which SwiftUI does handle.
    static func inline(_ text: String) -> AttributedString {
        var out = (try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
        // A code span set at the size of the words around it is wider and darker
        // than they are, and a paragraph with four of them stops being a
        // paragraph. A point smaller and on a faint ground, it reads as a name
        // inside a sentence, which is what it is.
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].font = .system(size: 11, design: .monospaced)
            out[run.range].backgroundColor = Color.primary.opacity(0.07)
        }
        return out
    }
}

/// Renders what `Markdown.parse` found.
struct MarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Markdown.parse(text)) { block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Markdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Markdown.inline(text))
                .font(level <= 2 ? Theme.Font.label : Theme.Font.reading.weight(.semibold))
                .padding(.top, Theme.Space.snug)

        case .paragraph(let text):
            Text(Markdown.inline(text))
                .font(Theme.Font.reading)
                .lineSpacing(Theme.leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 3) {
                if let language {
                    Text(language)
                        .font(Theme.Font.micro)
                        .foregroundStyle(.tertiary)
                }
                Text(text)
                    .font(Theme.Font.mono)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.step)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .fill(.primary.opacity(0.06)))

        case .list(let items, let ordered):
            // Items are paragraphs of their own here — a ticket and what happened
            // to it — so they are spaced as paragraphs. Three points apart they
            // ran together into one block with dots in it.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(Theme.Font.reading)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 10, alignment: .trailing)
                        Text(Markdown.inline(item))
                            .font(Theme.Font.reading)
                            .lineSpacing(Theme.leading)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: Theme.Space.step) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 2)
                Text(Markdown.inline(text))
                    .font(Theme.Font.reading)
                    .lineSpacing(Theme.leading)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)

        case .rule:
            Divider()
        }
    }
}

/// A table, laid out as one. These answers use them for exactly what a table is
/// for — a state of several things at once — and reading that as pipes is work.
private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: Theme.Space.gap,
             verticalSpacing: Theme.Space.snug) {
            if header.contains(where: { !$0.isEmpty }) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(Markdown.inline(header.indices.contains(column) ? header[column] : ""))
                            .font(Theme.Font.micro.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().opacity(0.3).gridCellColumns(columns)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(Markdown.inline(row.indices.contains(column) ? row[column] : ""))
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(Theme.Space.step)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(.primary.opacity(0.04)))
    }
}
