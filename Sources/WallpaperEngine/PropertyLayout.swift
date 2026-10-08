import Foundation

/// A run of properties under an optional `group` header, in authored order.
struct PropertySection: Identifiable {
    /// The group key, or a positional id for properties before the first group.
    let id: String
    let header: WallpaperProperty?
    let items: [WallpaperProperty]
}

enum PropertyLayout {
    /// Split ordered properties into sections at each `group` header.
    /// Windows app-launcher shortcuts have no macOS meaning and are omitted.
    static func sections(_ properties: [WallpaperProperty]) -> [PropertySection] {
        var sections: [PropertySection] = []
        var header: WallpaperProperty?
        var items: [WallpaperProperty] = []

        func flush() {
            guard header != nil || !items.isEmpty else { return }
            sections.append(PropertySection(id: header?.key ?? "section-\(sections.count)", header: header, items: items))
        }

        for property in properties where property.type != .usershortcut {
            if property.type == .group {
                flush()
                header = property
                items = []
            } else {
                items.append(property)
            }
        }
        flush()
        return sections
    }

    /// Render a WE label (authored as HTML) as plain text with working links.
    /// Returns nil when nothing readable remains, e.g. an image-only label.
    static func labelText(_ html: String) -> AttributedString? {
        var segments: [(text: String, link: URL?)] = []
        var remainder = Substring(html)
        let anchor = /<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a\s*>/
            .ignoresCase().dotMatchesNewlines()

        while let match = remainder.firstMatch(of: anchor) {
            segments.append((plainText(remainder[..<match.range.lowerBound]), nil))
            let title = plainText(match.output.2)
            if let url = URL(string: String(match.output.1)),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                segments.append((title.isEmpty ? url.host() ?? url.absoluteString : title, url))
            } else {
                segments.append((title, nil))
            }
            remainder = remainder[match.range.upperBound...]
        }
        segments.append((plainText(remainder), nil))

        // Drop the whitespace that surrounding HTML line breaks leave behind.
        segments = segments.filter { !$0.text.isEmpty }
        while let first = segments.first, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, first.link == nil {
            segments.removeFirst()
        }
        while let last = segments.last, last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, last.link == nil {
            segments.removeLast()
        }
        guard !segments.isEmpty else { return nil }
        segments[0].text = String(segments[0].text.drop { $0.isWhitespace })
        segments[segments.count - 1].text = String(segments[segments.count - 1].text.reversed().drop { $0.isWhitespace }.reversed())

        var result = AttributedString()
        for segment in segments {
            var run = AttributedString(segment.text)
            run.link = segment.link
            result += run
        }
        return result
    }

    /// Strip tags, turn block breaks into newlines and decode common entities.
    static func plainText<S: StringProtocol>(_ html: S) -> String {
        var text = String(html)
        text = text.replacing(/<\s*(br|hr|\/p|\/h[1-6]|\/div|\/li)\b[^>]*>/.ignoresCase(), with: "\n")
        text = text.replacing(/<[^>]*>/, with: "")
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        // Authors pad labels with invisible left-to-right marks.
        text = text.replacingOccurrences(of: "\u{200E}", with: "")
        text = text.replacing(/[ \t]*\n[ \t\n]*/, with: "\n")
        text = text.replacing(/[ \t]{2,}/, with: " ")
        return text
    }
}
