import Foundation

/// Release notes from GitHub, as plain text for an alert. GitHub writes them in Markdown,
/// which an alert would show raw (## headings, `code`, **bold**).
enum ReleaseNotes {
    /// The fingerprint of the app's source code that CI hides in release notes as
    /// "<!-- source: 3f9a… -->". Two builds with the same one are the same app, whatever
    /// their version numbers.
    static func sourceHash(in markdown: String) -> String? {
        guard let start = markdown.range(of: "<!-- source: "),
              let end = markdown.range(of: " -->", range: start.upperBound..<markdown.endIndex) else { return nil }
        let hash = markdown[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        return hash.isEmpty ? nil : hash
    }

    /// Headings become "Heading:", "- item" becomes "• item", and Markdown marks are dropped.
    /// Left out: the Install section (it's for people downloading by hand) and the line CI puts
    /// at the top of an alpha, which the alert already says in its own words.
    /// Longer than `limit` characters: cut at a line, ending with "…".
    static func plain(_ markdown: String, limit: Int = 600) -> String {
        var lines: [String] = []
        var skipping = false
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = clean(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                skipping = heading.lowercased() == "install"
                if skipping || heading.isEmpty { continue }
                if lines.last.map({ !$0.isEmpty }) == true { lines.append("") }
                lines.append(heading.hasSuffix(":") ? heading : heading + ":")
                continue
            }
            if skipping { continue }
            if line.hasPrefix("Alpha build from") || line.hasPrefix("<!--") { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
            line = clean(line)
            if line.isEmpty && (lines.last?.isEmpty ?? true) { continue }   // no doubled or leading blank lines
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }

        var text = ""
        for line in lines {
            let next = text.isEmpty ? line : text + "\n" + line
            if next.count > limit { return text.isEmpty ? String(line.prefix(limit)) + "…" : text + "\n…" }
            text = next
        }
        return text
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
