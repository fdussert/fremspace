import Foundation

// What a release tells the installed apps: the feed Sparkle reads (one item, the newest release;
// see docs/releasing.md) and, in it, the release notes, which are the changelog's section turned
// into the little HTML Sparkle's window shows. Used by scripts/appcast, never by the app itself.

/// The body of the section `## <version>` of a changelog, nil when there is none or it is empty.
/// The heading may carry more after the version ("## 0.2.0 - 2026-12-01").
public func changelogSection(_ changelog: String, version: String) -> String? {
    let lines = changelog.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "## \(version)" || $0.hasPrefix("## \(version) ")
    }) else { return nil }
    let rest = lines[(start + 1)...]
    let end = rest.firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
    let body = lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty ? nil : body
}

private func escapeXML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

private func replacing(_ pattern: String, with template: String, in text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
}

/// Code, bold and links: what a line of the changelog uses.
private func inlineHTML(_ text: String) -> String {
    var html = escapeXML(text)
    html = replacing("`([^`]+)`", with: "<code>$1</code>", in: html)
    html = replacing("\\*\\*([^*]+)\\*\\*", with: "<strong>$1</strong>", in: html)
    html = replacing("\\[([^\\]]+)\\]\\((https?:[^)\\s]+)\\)", with: "<a href=\"$2\">$1</a>", in: html)
    return html
}

/// Headings, bullet lists (with their wrapped continuation lines) and paragraphs, as HTML.
public func releaseNotesHTML(_ markdown: String) -> String {
    var out: [String] = []
    var list: [String]?
    var paragraph: String?
    func flush() {
        if let list { out.append("<ul>" + list.map { "<li>\(inlineHTML($0))</li>" }.joined() + "</ul>") }
        if let paragraph { out.append("<p>\(inlineHTML(paragraph))</p>") }
        list = nil
        paragraph = nil
    }
    for raw in markdown.components(separatedBy: "\n") {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            flush()
        } else if trimmed.hasPrefix("###") {
            flush()
            out.append("<h3>\(inlineHTML(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))</h3>")
        } else if !raw.hasPrefix(" "), trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            if paragraph != nil { flush() }
            list = (list ?? []) + [String(trimmed.dropFirst(2))]
        } else if list != nil, raw.hasPrefix(" ") {
            list![list!.count - 1] += " " + trimmed
        } else {
            if list != nil { flush() }
            paragraph = paragraph.map { "\($0) \(trimmed)" } ?? trimmed
        }
    }
    flush()
    return out.joined(separator: "\n")
}

/// The feed for one release: its version, the archive to download (`url`, `length` in bytes, its
/// EdDSA `signature` from Sparkle's sign_update) and its notes.
public func appcast(version: String, url: String, length: Int, signature: String, notesHTML: String, date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>Fremspace</title>
        <link>https://fremspace.app/</link>
        <item>
          <title>Fremspace \(escapeXML(version))</title>
          <pubDate>\(formatter.string(from: date))</pubDate>
          <sparkle:version>\(escapeXML(version))</sparkle:version>
          <sparkle:shortVersionString>\(escapeXML(version))</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
          <description><![CDATA[\(notesHTML.replacingOccurrences(of: "]]>", with: "]]&gt;"))]]></description>
          <enclosure url="\(escapeXML(url))" length="\(length)" type="application/octet-stream" sparkle:edSignature="\(escapeXML(signature))"/>
        </item>
      </channel>
    </rss>

    """
}
