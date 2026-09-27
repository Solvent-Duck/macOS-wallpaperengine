import CoreGraphics
import CoreText
import Foundation
import NativeSceneCore

struct TextLayoutConfiguration: Decodable, Equatable, Sendable {
    let content: String
    let fontPath: String
    let pointSize: Double
    let maxWidth: Double
    let maxRows: Int
    let padding: Int
    let horizontalAlign: String
    let verticalAlign: String
    let limitWidth: Bool
    let limitRows: Bool
    let limitUseEllipsis: Bool
    let blockAlign: Bool

    init(_ text: FrameText) {
        content = text.content; fontPath = text.fontPath; pointSize = text.pointSize
        maxWidth = text.maxWidth; maxRows = text.maxRows; padding = text.padding
        horizontalAlign = text.horizontalAlign; verticalAlign = text.verticalAlign
        limitWidth = text.limitWidth; limitRows = text.limitRows
        limitUseEllipsis = text.limitUseEllipsis; blockAlign = text.blockAlign
    }
}

public enum TextLayoutError: LocalizedError {
    case invalidDimensions(String)
    public var errorDescription: String? {
        switch self { case .invalidDimensions(let message): return message }
    }
}

fileprivate struct TextLayoutLine {
    let line: CTLine
    let origin: CGPoint
    let ascent: CGFloat
    let descent: CGFloat
}

public struct TextLayout {
    public let width: Int
    public let height: Int
    public let contentHeight: CGFloat
    fileprivate let lines: [TextLayoutLine]

    public func draw(in context: CGContext, origin: CGPoint, shadow: Bool) {
        context.saveGState()
        defer { context.restoreGState() }

        if shadow {
            context.setShadow(
                offset: CGSize(width: 1, height: -1),
                blur: 0,
                color: CGColor(gray: 0, alpha: 0.35)
            )
        }

        for line in lines {
            context.textPosition = CGPoint(
                x: origin.x + line.origin.x,
                y: origin.y + line.origin.y
            )
            CTLineDraw(line.line, context)
        }
    }

}

/// Shared by SceneScript size queries and the renderer. Each layer retains
/// only its latest layout, including while clocks and media text change.
public final class TextLayoutEngine: @unchecked Sendable {
    private static let pixelsPerPoint: CGFloat = 300 / 72
    private let assetRoots: [URL]
    private let lock = NSRecursiveLock()
    private var fontCache: [String: CTFont] = [:]
    private var cache: [NodeID: (configuration: TextLayoutConfiguration, layout: TextLayout?)] = [:]

    public init(assetRoots: [URL]) { self.assetRoots = assetRoots }

    func remove(nodeIDs: Set<NodeID>) {
        lock.lock(); defer { lock.unlock() }
        for id in nodeIDs { cache[id] = nil }
    }

    public func layout(for text: FrameText) throws -> TextLayout? {
        try layout(nodeID: text.nodeID, configuration: TextLayoutConfiguration(text))
    }

    func layout(nodeID: NodeID, configuration text: TextLayoutConfiguration) throws -> TextLayout? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[nodeID], cached.configuration == text { return cached.layout }
        let layout = try makeMeasuredLayout(text)
        cache[nodeID] = (text, layout)
        return layout
    }

    private func makeMeasuredLayout(_ text: TextLayoutConfiguration) throws -> TextLayout? {
        let content = text.content.replacingOccurrences(of: "\0", with: "")
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard text.pointSize.isFinite, text.maxWidth.isFinite else {
            throw TextLayoutError.invalidDimensions("text dimensions must be finite")
        }
        // A zero point size hides text; Core Text interprets zero as its own
        // default size, so do not pass it through to the font constructor.
        guard text.pointSize > 0 else { return nil }
        guard text.pointSize * Double(Self.pixelsPerPoint) <= 16384 else {
            throw TextLayoutError.invalidDimensions("text point size exceeds the maximum texture dimension")
        }
        let font = resolveFont(path: text.fontPath, pointSize: CGFloat(text.pointSize) * Self.pixelsPerPoint)
        let attributes = makeAttributes(text: text, font: font)
        let attributed = NSAttributedString(string: content, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constrainedWidth = text.limitWidth && text.maxWidth > 0 ? CGFloat(text.maxWidth) : CGFloat.greatestFiniteMagnitude
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: constrainedWidth, height: .greatestFiniteMagnitude), nil)
        let drawWidth = max(ceil(text.limitWidth && text.maxWidth > 0 ? constrainedWidth : measured.width), 1)
        // Height is measured from the current string. Saved size is an editor
        // snapshot, not a clipping rectangle for scripts or user text.
        let measuredHeight = max(ceil(measured.height), 1)
        let layoutHeight = text.limitRows && text.maxRows > 0
            ? min(measuredHeight, 16384)
            : measuredHeight
        guard drawWidth.isFinite, layoutHeight.isFinite, drawWidth <= 16384, layoutHeight <= 16384 else {
            throw TextLayoutError.invalidDimensions("text layout exceeds the maximum texture dimension")
        }
        guard let layout = makeLayout(attributed: attributed, text: text, drawWidth: drawWidth, drawHeight: layoutHeight) else {
            return nil
        }
        let padding = max(text.padding, 0)
        guard padding <= 8191 else {
            throw TextLayoutError.invalidDimensions("text padding exceeds the maximum texture dimension")
        }
        let width = Int(drawWidth) + padding * 2
        let height = max(Int(ceil(layout.contentHeight)), 1) + padding * 2
        guard width <= 16384, height <= 16384 else {
            throw TextLayoutError.invalidDimensions("padded text exceeds the maximum texture dimension")
        }
        return TextLayout(width: width, height: height, contentHeight: layout.contentHeight, lines: layout.lines)
    }

    private struct LaidOutText {
        let lines: [TextLayoutLine]
        let contentHeight: CGFloat
    }

    private func makeLayout(
        attributed: NSAttributedString,
        text: TextLayoutConfiguration,
        drawWidth: CGFloat,
        drawHeight: CGFloat
    ) -> LaidOutText? {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // Measured text extents use integer pixels. Core Text rounds ascent and
        // descent separately when fitting a frame, which can reject a line
        // whose metrics otherwise fit. Two virtual pixels cover that rounding;
        // normalized baselines still align within the original texture bounds.
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight + 2), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let frameLines = CTFrameGetLines(frame) as NSArray
        guard frameLines.count > 0 else {
            return nil
        }

        let lineCount = frameLines.count
        let visibleCount = text.limitRows && text.maxRows > 0 ? min(text.maxRows, lineCount) : lineCount
        var lineOrigins = [CGPoint](repeating: .zero, count: lineCount)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &lineOrigins)

        var lines: [TextLayoutLine] = []
        lines.reserveCapacity(visibleCount)

        for index in 0..<visibleCount {
            let line = frameLines[index] as! CTLine
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            lines.append(TextLayoutLine(line: line, origin: lineOrigins[index], ascent: ascent, descent: descent))
        }

        let fittedRange = CTFrameGetVisibleStringRange(frame)
        let hasOverflow = visibleCount < lineCount || fittedRange.location + fittedRange.length < attributed.length
        if text.limitRows && text.limitUseEllipsis && hasOverflow, let lastIndex = lines.indices.last {
            let token = NSAttributedString(string: "\u{2026}", attributes: attributed.attributes(at: 0, effectiveRange: nil))
            let tokenLine = CTLineCreateWithAttributedString(token)
            let line = lines[lastIndex]
            let range = CTLineGetStringRange(line.line)
            let remainder = NSMutableAttributedString(attributedString: attributed.attributedSubstring(
                from: NSRange(location: range.location, length: range.length)))
            while remainder.length > 0, let last = remainder.string.unicodeScalars.last,
                  CharacterSet.whitespacesAndNewlines.contains(last) {
                let lastRange = (remainder.string as NSString).rangeOfComposedCharacterSequence(at: remainder.length - 1)
                remainder.deleteCharacters(in: lastRange)
            }
            remainder.append(token)
            let candidate = CTLineCreateWithAttributedString(remainder)
            let truncated = CTLineCreateTruncatedLine(candidate, Double(drawWidth), .end, tokenLine) ?? tokenLine
            let flush: CGFloat = text.horizontalAlign.lowercased() == "left" ? 0 : text.horizontalAlign.lowercased() == "right" ? 1 : 0.5
            lines[lastIndex] = TextLayoutLine(line: truncated,
                origin: CGPoint(x: CTLineGetPenOffsetForFlush(truncated, flush, Double(drawWidth)), y: line.origin.y),
                ascent: line.ascent, descent: line.descent)
        }

        let contentTop = lines.map { $0.origin.y + $0.ascent }.max() ?? 0
        let contentBottom = lines.map { $0.origin.y - $0.descent }.min() ?? 0
        let contentHeight = max(contentTop - contentBottom, 0)
        // Core Text locates lines within the entire frame. Normalize their
        // baseline coordinates before placing that content at its alignment.
        let normalizedLines = lines.map { line in
            TextLayoutLine(line: line.line,
                           origin: CGPoint(x: line.origin.x, y: line.origin.y - contentBottom),
                           ascent: line.ascent, descent: line.descent)
        }
        return LaidOutText(lines: normalizedLines, contentHeight: contentHeight)
    }

    private func makeAttributes(text: TextLayoutConfiguration, font: CTFont) -> [NSAttributedString.Key: Any] {
        let alignment: CTTextAlignment
        switch text.horizontalAlign.lowercased() {
        case "left":
            alignment = .left
        case "right":
            alignment = .right
        case "block":
            alignment = .justified
        default:
            alignment = text.blockAlign ? .justified : .center
        }

        var lineBreak = CTLineBreakMode.byClipping
        if text.limitWidth || text.limitRows || text.blockAlign {
            lineBreak = .byWordWrapping
        } else if text.limitUseEllipsis {
            lineBreak = .byTruncatingTail
        }

        var mutableAlignment = alignment
        var mutableLineBreak = lineBreak
        let paragraphStyle = withUnsafePointer(to: &mutableAlignment) { alignmentPointer in
            withUnsafePointer(to: &mutableLineBreak) { lineBreakPointer in
                var paragraphSettings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.stride,
                        value: alignmentPointer
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineBreakMode,
                        valueSize: MemoryLayout<CTLineBreakMode>.stride,
                        value: lineBreakPointer
                    ),
                ]
                return CTParagraphStyleCreate(&paragraphSettings, paragraphSettings.count)
            }
        }
        return [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
        ]
    }

    private func resolveFont(path: String, pointSize: CGFloat) -> CTFont {
        let cacheKey = "\(path)|\(pointSize)"
        if let cached = fontCache[cacheKey] {
            return cached
        }

        // Animated point sizes must not retain a new font forever.
        if fontCache.count >= 128 { fontCache.removeAll(keepingCapacity: true) }
        if let fontURL = resolveAsset(path: path),
           let provider = CGDataProvider(url: fontURL as CFURL),
           let cgFont = CGFont(provider) {
            let font = CTFontCreateWithGraphicsFont(cgFont, pointSize, nil, nil)
            fontCache[cacheKey] = font
            return font
        }

        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let font = CTFontCreateWithName(name as CFString, pointSize, nil)
        fontCache[cacheKey] = font
        return font
    }

    private func resolveAsset(path: String) -> URL? {
        let candidate = URL(fileURLWithPath: path)
        if candidate.isFileURL, FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        for root in assetRoots {
            let url = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

}
