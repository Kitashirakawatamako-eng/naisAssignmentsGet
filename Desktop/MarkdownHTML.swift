import Foundation

/// Minimal Markdown to HTML for the drafts the assistant writes: headings, tables, lists,
/// emphasis, code fences, rules and links. Everything is escaped first, so page text cannot
/// inject markup.
enum MarkdownHTML {
    static func render(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var html: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { index += 1; continue }

            if trimmed.hasPrefix("```") {
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(escape(lines[index])); index += 1
                }
                index += 1
                html.append("<pre><code>" + code.joined(separator: "\n") + "</code></pre>")
                continue
            }

            if let level = headingLevel(trimmed) {
                let text = inline(String(trimmed.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces))
                html.append("<h\(level)>\(text)</h\(level)>")
                index += 1
                continue
            }

            if isRule(trimmed) {
                html.append("<hr>"); index += 1; continue
            }

            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                let header = cells(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index])); index += 1
                }
                var table = "<table><thead><tr>"
                table += header.map { "<th>\(inline($0))</th>" }.joined()
                table += "</tr></thead><tbody>"
                for row in rows {
                    table += "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
                }
                table += "</tbody></table>"
                html.append(table)
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || isOrdered(trimmed) {
                let ordered = isOrdered(trimmed)
                var items: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix("- ") || candidate.hasPrefix("* ") || isOrdered(candidate) else { break }
                    let body = ordered
                        ? candidate.replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression)
                        : String(candidate.dropFirst(2))
                    items.append("<li>\(inline(body))</li>")
                    index += 1
                }
                html.append(ordered ? "<ol>" + items.joined() + "</ol>" : "<ul>" + items.joined() + "</ul>")
                continue
            }

            if trimmed.hasPrefix("> ") {
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("> ") {
                    quote.append(inline(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst(2))))
                    index += 1
                }
                html.append("<blockquote>" + quote.joined(separator: "<br>") + "</blockquote>")
                continue
            }

            var paragraph: [String] = []
            while index < lines.count {
                let candidate = lines[index]
                let text = candidate.trimmingCharacters(in: .whitespaces)
                if text.isEmpty || headingLevel(text) != nil || isRule(text) || text.hasPrefix("```")
                    || text.hasPrefix("|") || text.hasPrefix("- ") || text.hasPrefix("* ")
                    || text.hasPrefix("> ") || isOrdered(text) { break }
                paragraph.append(inline(text))
                index += 1
            }
            if !paragraph.isEmpty {
                html.append("<p>" + paragraph.joined(separator: " ") + "</p>")
            } else {
                index += 1
            }
        }
        return document(html.joined(separator: "\n"))
    }

    private static func document(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, "SF Pro Text", "PingFang SC", sans-serif; margin: 0;
               padding: 2px 6px 10px; line-height: 1.5; color: #1c1c1e; background: transparent;
               -webkit-font-smoothing: antialiased; }
        h1 { font-size: 17px; margin: 4px 0 8px; }
        h2 { font-size: 15px; margin: 14px 0 6px; }
        h3, h4, h5, h6 { font-size: 13px; margin: 12px 0 4px; }
        p { margin: 6px 0; }
        hr { border: none; border-top: 1px solid rgba(0,0,0,0.12); margin: 12px 0; }
        table { border-collapse: collapse; margin: 8px 0; width: 100%; }
        th, td { border: 1px solid rgba(0,0,0,0.15); padding: 4px 7px; text-align: left; vertical-align: top; }
        th { background: rgba(0,0,0,0.04); font-weight: 600; }
        code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; background: rgba(0,0,0,0.06);
               padding: 1px 4px; border-radius: 4px; }
        pre { background: rgba(0,0,0,0.06); padding: 8px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 8px 0; padding-left: 10px; border-left: 3px solid rgba(0,0,0,0.15); color: #555; }
        ul, ol { margin: 6px 0 6px 18px; padding: 0; }
        li { margin: 2px 0; }
        a { color: #1f6b58; }
        @media (prefers-color-scheme: dark) {
            body { color: #e9e9ea; }
            hr, th, td { border-color: rgba(255,255,255,0.18); }
            th, code, pre { background: rgba(255,255,255,0.09); }
            blockquote { border-color: rgba(255,255,255,0.22); color: #c7c7cc; }
            a { color: #7fd3bd; }
        }
        </style></head><body>\(body)</body></html>
        """
    }

    private static func headingLevel(_ text: String) -> Int? {
        let hashes = text.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), text.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isRule(_ text: String) -> Bool {
        text == "---" || text == "***" || text == "___"
    }

    private static func isOrdered(_ text: String) -> Bool {
        text.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = cells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } && cell.contains("-")
        }
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ text: String) -> String {
        var result = escape(text)
        result = result.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?<![\w*])\*([^*]+)\*(?![\w*])"#, with: "<em>$1</em>", options: .regularExpression)
        result = result.replacingOccurrences(of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)]+)\)"#, with: #"<a href="$2">$1</a>"#, options: .regularExpression)
        return result
    }
}
