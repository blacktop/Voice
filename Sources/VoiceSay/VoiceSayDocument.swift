import Foundation
import VoiceMLX

/// Local prose extraction for listening: fenced code and URL paths are never
/// spoken. Each paragraph-sized run of text carries the role that reads it, so
/// headings, quotations, and the labels standing in for omitted material can
/// be cast to a different voice than the prose. Omitted material gets a brief
/// label so its presence is clear.
enum VoiceSayDocument {
    static func blocks(from source: String) -> [SpeechNarrationBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var scan = Scan()
        for line in documentLines(normalized.components(separatedBy: "\n")) {
            scan.consume(line)
        }
        scan.finish()
        return group(separateListItems(summarizeTables(scan.lines))).compactMap {
            block($0.role, lines: $0.lines)
        }
    }

    private static func documentLines(_ lines: [String]) -> ArraySlice<String> {
        guard lines.first == "---",
            let end = lines.indices.dropFirst().first(where: {
                lines[$0] == "---" || lines[$0] == "..."
            })
        else { return lines[...] }
        return lines[(end + 1)...]
    }

    private enum Line: Equatable {
        case blank
        case text(SpeechNarrationRole, String)
    }

    /// The line pass. Only explicit code fences and HTML tables consume text
    /// across lines; indentation alone may be ordinary prose or an error.
    private struct Scan {
        var lines: [Line] = []
        private var fence: (marker: Character, count: Int, language: String)?
        private var inHTMLTable = false

        mutating func consume(_ line: String) {
            let candidate = replacing(blockquotePrefix, in: line, with: "")
            let quoted = candidate != line
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if consumeFencedCode(trimmed) { return }
            if consumeHTMLTable(trimmed) { return }
            if openFence(candidate) { return }
            if consumeHeading(candidate) { return }
            if consumeRule(trimmed) { return }
            if trimmed.isEmpty || matches(linkReferenceDefinition, candidate) {
                lines.append(.blank)
                return
            }
            lines.append(.text(quoted ? .quote : .narrator, candidate))
        }

        mutating func finish() {
            if let fence { appendCode(language: fence.language) }
        }

        private mutating func consumeFencedCode(_ trimmed: String) -> Bool {
            guard let open = fence else { return false }
            let count = trimmed.prefix(while: { $0 == open.marker }).count
            if count >= open.count,
                trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
            {
                appendCode(language: open.language)
                fence = nil
            }
            return true
        }

        /// An HTML block starting with `<table` is swallowed through its
        /// closing tag. Only a tag at the start of a line opens one, so a
        /// mention of the tag in prose cannot swallow the rest of the document.
        private mutating func consumeHTMLTable(_ trimmed: String) -> Bool {
            let lowered = trimmed.lowercased()
            if inHTMLTable {
                if lowered.contains("</table") {
                    inHTMLTable = false
                    appendAside("Table.")
                }
                return true
            }
            guard lowered.hasPrefix("<table") else { return false }
            if lowered.contains("</table") {
                appendAside("Table.")
            } else {
                inHTMLTable = true
            }
            return true
        }

        private mutating func openFence(_ candidate: String) -> Bool {
            let opening = replacing(listMarker, in: candidate, with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let marker = opening.first, marker == "`" || marker == "~" else { return false }
            let count = opening.prefix(while: { $0 == marker }).count
            let info = opening.dropFirst(count)
            guard count >= 3, marker != "`" || !info.contains("`") else { return false }
            fence = (
                marker, count, String(info.split(whereSeparator: \.isWhitespace).first ?? "")
            )
            return true
        }

        private mutating func consumeHeading(_ candidate: String) -> Bool {
            guard let regex = atxHeading else { return false }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range) else { return false }
            var title = ""
            if let titleRange = Range(match.range(at: 1), in: candidate) {
                title = replacing(closingHashes, in: String(candidate[titleRange]), with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            appendHeading(title)
            return true
        }

        /// A run of `=` or `-` under a one-line paragraph is a setext heading;
        /// otherwise a run of `-`, `*`, or `_` is a thematic break, which is
        /// heard as a paragraph break and never spoken.
        private mutating func consumeRule(_ trimmed: String) -> Bool {
            if matches(setextUnderline, trimmed),
                case .text(let role, let text)? = lines.last, role == .narrator || role == .quote,
                lines.count < 2 || lines[lines.count - 2] == .blank
            {
                lines.removeLast()
                appendHeading(text.trimmingCharacters(in: .whitespaces))
                return true
            }
            guard matches(thematicBreak, trimmed) else { return false }
            lines.append(.blank)
            return true
        }

        private mutating func appendHeading(_ title: String) {
            guard !title.isEmpty else {
                lines.append(.blank)
                return
            }
            lines.append(contentsOf: [.blank, .text(.heading, title), .blank])
        }

        private mutating func appendAside(_ label: String) {
            lines.append(contentsOf: [.blank, .text(.aside, label), .blank])
        }

        private mutating func appendCode(language: String) {
            appendAside(codeLabel(language) + ".")
        }
    }

    /// Table detection runs first because a delimiter row can start with `- `.
    private static func separateListItems(_ lines: [Line]) -> [Line] {
        lines.flatMap { line in
            guard case .text(let role, let text) = line, role == .narrator || role == .quote,
                matches(listMarker, text)
            else { return [line] }
            let item = replacing(listMarker, in: text, with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { return [.blank] }
            let sentence = matches(sentenceEnd, item) ? item : item + "."
            return [.blank, .text(role, sentence), .blank]
        }
    }

    /// Consecutive lines in one role form a block; a blank line or a change
    /// of role ends it.
    private static func group(_ lines: [Line]) -> [(role: SpeechNarrationRole, lines: [String])] {
        var blocks: [(role: SpeechNarrationRole, lines: [String])] = []
        var current: (role: SpeechNarrationRole, lines: [String])?
        for line in lines {
            switch line {
            case .blank:
                if let current { blocks.append(current) }
                current = nil
            case .text(let role, let text):
                if current?.role == role {
                    current?.lines.append(text)
                } else {
                    if let current { blocks.append(current) }
                    current = (role, [text])
                }
            }
        }
        if let current { blocks.append(current) }
        return blocks
    }

    /// Inline cleanup of one block. Labels replace Markdown destinations, then
    /// bare URLs (autolinks included) are summarized by the data detector. A
    /// paragraph that is nothing but a URL is an aside; one that is entirely a
    /// quotation is read as a quote.
    private static func block(_ role: SpeechNarrationRole, lines: [String]) -> SpeechNarrationBlock?
    {
        var text = lines.joined(separator: "\n")
        text = replacing(inlineLink, in: text, with: "$1")
        text = replacing(referenceLink, in: text, with: "$1")
        text = replacing(autolink, in: text, with: "$1")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var role = role
        if let detector = linkDetector {
            let whole = NSRange(text.startIndex..<text.endIndex, in: text)
            let links = detector.matches(in: text, range: whole).filter {
                $0.url?.scheme != "mailto"
            }
            if role == .narrator, links.count == 1, links[0].range == whole {
                role = .aside
            }
            for match in links.reversed() {
                guard let url = match.url, let range = Range(match.range, in: text) else {
                    continue
                }
                text.replaceSubrange(range, with: urlLabel(url, original: String(text[range])))
            }
        }
        text = replacing(hexAddress, in: text, with: "code address")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if role == .narrator, isQuotation(text) { role = .quote }
        return SpeechNarrationBlock(role: role, text: text)
    }

    /// Opens and closes with a quotation mark and contains no other, so the
    /// whole paragraph is one quotation rather than dialogue with narration.
    private static func isQuotation(_ text: String) -> Bool {
        guard text.count >= 2, let first = text.first, let last = text.last,
            "\"“".contains(first), "\"”".contains(last)
        else { return false }
        return !text.dropFirst().dropLast().contains(where: { "\"“”".contains($0) })
    }

    // NSRegularExpression is immutable and thread-safe, so each pattern is
    // compiled once rather than on every line of a long document.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let blockquotePrefix = expression(#"^\s*(?:>\s*)+"#)
    private static let listMarker = expression(
        #"^[ \t]*(?:[-+*]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"#)
    private static let sentenceEnd = expression(#"[.!?…][\"'”’)\]]*$"#)
    private static let linkReferenceDefinition = expression(#"^\s{0,3}\[[^\]]+\]:\s*\S"#)
    private static let atxHeading = expression(#"^\s{0,3}#{1,6}(?:\s+(.*?))?\s*$"#)
    private static let closingHashes = expression(#"(?:^|\s)#+\s*$"#)
    private static let setextUnderline = expression(#"^(?:=+|-+)$"#)
    private static let thematicBreak = expression(#"^([-*_])(?:\s*\1){2,}$"#)
    private static let inlineLink = expression(#"!?\[([^\]\n]*)\]\((?:[^()\n]|\([^()\n]*\))*\)"#)
    private static let referenceLink = expression(#"\[([^\]\n]+)\]\[[^\]\n]*\]"#)
    private static let autolink = expression(#"<((?:[a-zA-Z][a-zA-Z0-9+.-]*://|www\.)[^>\s]+)>"#)
    private static let hexAddress = expression(#"(?i)(?<![a-z0-9_])0x[0-9a-f]{8,}(?![a-z0-9_])"#)
    private static let tableDelimiterCell = expression(#"^:?-+:?$"#)

    private static func expression(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func codeLabel(_ language: String) -> String {
        switch language.lowercased() {
        case "c", "h": "C code"
        case "cpp", "c++", "cxx": "C plus plus code"
        case "objc", "objective-c": "Objective C code"
        case "swift": "Swift code"
        case "rust", "rs": "Rust code"
        case "python", "py": "Python code"
        case "javascript", "js", "jsx": "JavaScript code"
        case "typescript", "ts", "tsx": "TypeScript code"
        case "go", "golang": "Go code"
        case "bash", "sh", "zsh", "fish", "shell": "Shell code"
        case "asm", "assembly": "Assembly code"
        case "json": "JSON code"
        default: "Code block"
        }
    }

    /// A pipe-containing header followed by a Markdown delimiter row starts a
    /// table. Ordinary prose containing a pipe alone remains prose.
    private static func summarizeTables(_ lines: [Line]) -> [Line] {
        var result: [Line] = []
        var index = 0
        while index < lines.count {
            if case .text(_, let header) = lines[index], header.contains("|"),
                index + 1 < lines.count, case .text(_, let delimiter) = lines[index + 1],
                isTableDelimiter(delimiter)
            {
                result.append(contentsOf: [.blank, .text(.aside, "Table."), .blank])
                index += 2
                while index < lines.count, case .text(_, let row) = lines[index],
                    row.contains("|")
                {
                    index += 1
                }
            } else {
                result.append(lines[index])
                index += 1
            }
        }
        return result
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        var cells = trimmed.components(separatedBy: "|")
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return !cells.isEmpty
            && cells.allSatisfy {
                matches(tableDelimiterCell, $0.trimmingCharacters(in: .whitespaces))
            }
    }

    private static func urlLabel(_ url: URL, original: String) -> String {
        guard var host = url.host, !host.isEmpty else { return "URL" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let spokenHost = host.replacingOccurrences(of: ".", with: " dot ")
        guard original.count > 48 || url.query != nil || url.fragment != nil else {
            return spokenHost
        }
        // Shorten only an unambiguous two-label host. Keep subdomains and
        // compound suffixes explicit rather than guessing a registrable domain.
        let parts = host.split(separator: ".")
        if parts.count == 2, let name = parts.first, let suffix = parts.last,
            ["com", "org", "net", "edu", "gov", "io", "ai", "dev", "app"].contains(String(suffix))
        {
            return "\(name) URL"
        }
        return spokenHost + " URL"
    }

    private static func replacing(
        _ regex: NSRegularExpression?, in text: String, with template: String
    ) -> String {
        guard let regex else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: template
        )
    }

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
