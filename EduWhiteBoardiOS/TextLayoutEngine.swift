import CoreText
import Foundation
import SwiftUI
import UIKit

struct CharacterBox: Hashable {
    let index: Int
    let char: String
    let rect: CGRect
    let lineIndex: Int
}

struct LineRect: Hashable {
    let lineIndex: Int
    let rect: CGRect
}

struct TextLayoutResult {
    let characterBoxes: [CharacterBox]
    let contentHeight: CGFloat
}

@MainActor
enum TextLayoutEngine {
    static let fallbackFontName = "PingFangSC-Regular"
    static let handwritingFontCandidates = [
        "MaShanZheng-Regular",
        "HannotateSC-W5",
        "HannotateSC-W7",
        "HanziPenSC-W3",
        "HanziPenSC-W5",
        "STXingkaiSC-Light",
        "STKaitiSC-Regular",
        "STKaiti",
        "BiauKaiTC-Regular",
        "BiauKaiHK-Regular",
        "Kailasa",
        "MarkerFelt-Thin",
        "ChalkboardSE-Regular",
    ]
    static let latinHandwritingFontCandidates = [
        "ShantellSans-Light",
        "MarkerFelt-Thin",
        "ChalkboardSE-Regular",
    ]
    static let handwritingFontName = handwritingFontCandidates.first(where: fontSupportsSampleText) ?? fallbackFontName
    static let latinHandwritingFontName = latinHandwritingFontCandidates.first(where: fontSupportsLatinSampleText)

    static func font(size: CGFloat) -> UIFont {
        let primaryDescriptor = fontDescriptor(named: handwritingFontName, size: size)

        guard let latinHandwritingFontName, latinHandwritingFontName != handwritingFontName else {
            return UIFont(descriptor: primaryDescriptor, size: size)
        }

        let cascadedDescriptor = primaryDescriptor.addingAttributes([
            .cascadeList: [fontDescriptor(named: latinHandwritingFontName, size: size)],
        ])
        return UIFont(descriptor: cascadedDescriptor, size: size)
    }

    static func displayFont(size: CGFloat) -> Font {
        Font(font(size: size))
    }

    static func strokeSelectionIndexes(
        points: [CGPoint],
        boxes: [CharacterBox],
        padding: CGFloat = WhiteboardConstants.markHitPadding
    ) -> [Int] {
        guard !points.isEmpty else {
            return []
        }

        let sweepRect = strokeBoundingRect(points: points, padding: padding * 0.6)
        let useSweepEnvelope = sweepRect.width > 14 || sweepRect.height > 14 || points.count > 2

        let hitIndexes = boxes.compactMap { box -> Int? in
            if strokeHitsCharacterBox(points: points, box: box, padding: padding) {
                return box.index
            }

            guard useSweepEnvelope else {
                return nil
            }

            let envelopeRect = box.rect.insetBy(dx: -padding * 0.8, dy: -padding * 0.35)
            return sweepRect.intersects(envelopeRect) ? box.index : nil
        }

        return Array(Set(hitIndexes)).sorted()
    }

    static func layout(text: String, cardWidth: CGFloat, fontSize: CGFloat, lineHeight: CGFloat) -> TextLayoutResult {
        let contentWidth = max(1, cardWidth - WhiteboardConstants.textPadding * 2)
        let font = font(size: fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = lineHeight
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle,
        ]

        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes)
        let textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lineRanges: [(range: NSRange, index: Int)] = []
        var glyphIndex = glyphRange.location
        var lineIndex = 0

        while glyphIndex < NSMaxRange(glyphRange) {
            var effectiveRange = NSRange(location: 0, length: 0)
            _ = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: &effectiveRange)
            lineRanges.append((effectiveRange, lineIndex))
            glyphIndex = NSMaxRange(effectiveRange)
            lineIndex += 1
        }

        let nsText = text as NSString
        let length = nsText.length
        var characterBoxes: [CharacterBox] = []
        characterBoxes.reserveCapacity(length)
        var lastLineIndex = 0

        if length > 0 {
            for characterIndex in 0..<length {
                let charRange = NSRange(location: characterIndex, length: 1)
                let glyphRangeForCharacter = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
                let char = nsText.substring(with: charRange)

                if glyphRangeForCharacter.length == 0 {
                    characterBoxes.append(
                        CharacterBox(
                            index: characterIndex,
                            char: char,
                            rect: CGRect(x: WhiteboardConstants.textPadding, y: WhiteboardConstants.textPadding, width: 0, height: 0),
                            lineIndex: lastLineIndex
                        )
                    )
                    continue
                }

                var combinedRect = CGRect.null
                for glyph in glyphRangeForCharacter.location..<NSMaxRange(glyphRangeForCharacter) {
                    let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                    combinedRect = combinedRect.union(glyphRect)
                }

                let resolvedLineIndex = lineRanges.first(where: { NSLocationInRange(glyphRangeForCharacter.location, $0.range) })?.index ?? lastLineIndex
                lastLineIndex = resolvedLineIndex

                let rect = combinedRect.isNull
                    ? CGRect(x: 0, y: 0, width: 0, height: font.lineHeight)
                    : combinedRect

                characterBoxes.append(
                    CharacterBox(
                        index: characterIndex,
                        char: char,
                        rect: rect.offsetBy(dx: WhiteboardConstants.textPadding, dy: WhiteboardConstants.textPadding),
                        lineIndex: resolvedLineIndex
                    )
                )
            }
        }

        let usedRect = layoutManager.usedRect(for: textContainer)
        let minimumHeight = font.lineHeight * max(lineHeight, 1)
        let contentHeight = max(usedRect.height, minimumHeight) + WhiteboardConstants.textPadding * 2

        return TextLayoutResult(characterBoxes: characterBoxes, contentHeight: contentHeight)
    }

    static func estimatedCardSize(
        for text: String,
        viewportWidth: CGFloat?,
        fontSize: CGFloat = WhiteboardConstants.defaultFontSize,
        lineHeight: CGFloat = WhiteboardConstants.defaultLineHeight
    ) -> CGSize {
        let font = font(size: fontSize)
        let availableWidth = max(viewportWidth ?? WhiteboardConstants.defaultCardWidth, WhiteboardConstants.minimumCardWidth)
        let maxWidth = max(WhiteboardConstants.minimumCardWidth, availableWidth * WhiteboardConstants.asrMaxWidthRatio)
        let minimumWidth = min(WhiteboardConstants.defaultCardWidth, maxWidth)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = lineHeight

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let widestLine = lines.reduce(CGFloat.zero) { partial, line in
            let measured = (String(line) as NSString).size(withAttributes: [.font: font]).width
            return max(partial, measured)
        }

        let width = max(minimumWidth, min(maxWidth, ceil(widestLine + WhiteboardConstants.textPadding * 2 + fontSize * 0.5)))

        let contentWidth = max(1, width - WhiteboardConstants.textPadding * 2)
        let estimatedLineCount = max(
            1,
            lines.reduce(0) { partial, line in
                let lineWidth = max((String(line) as NSString).size(withAttributes: [.font: font]).width, 1)
                return partial + Int(ceil(lineWidth / contentWidth))
            }
        )

        let height = max(
            WhiteboardConstants.defaultCardHeight,
            ceil(CGFloat(estimatedLineCount) * fontSize * lineHeight + WhiteboardConstants.textPadding * 2)
        )

        return CGSize(width: width, height: height)
    }

    static func trimmedRange(in text: String, start: Int, end: Int) -> Range<Int>? {
        let nsText = text as NSString
        var nextStart = max(0, min(start, nsText.length))
        var nextEnd = max(nextStart, min(end, nsText.length))

        while nextStart < nextEnd {
            let chunk = nsText.substring(with: NSRange(location: nextStart, length: 1))
            if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nextStart += 1
            } else {
                break
            }
        }

        while nextEnd > nextStart {
            let chunk = nsText.substring(with: NSRange(location: nextEnd - 1, length: 1))
            if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nextEnd -= 1
            } else {
                break
            }
        }

        guard nextStart < nextEnd else {
            return nil
        }

        return nextStart..<nextEnd
    }

    static func hasAnnotationConflict(start: Int, end: Int, annotations: [TextAnnotation]) -> Bool {
        annotations.contains { annotation in
            start < annotation.end && end > annotation.start
        }
    }

    static func annotationRects(in boxes: [CharacterBox], annotation: TextAnnotation) -> [LineRect] {
        let relevant = boxes.filter { box in
            box.index >= annotation.start && box.index < annotation.end && box.char != "\n"
        }

        guard !relevant.isEmpty else {
            return []
        }

        let grouped = Dictionary(grouping: relevant, by: \.lineIndex)
        return grouped.keys.sorted().compactMap { key in
            guard let lineBoxes = grouped[key] else {
                return nil
            }

            let minX = lineBoxes.map(\.rect.minX).min() ?? 0
            let minY = lineBoxes.map(\.rect.minY).min() ?? 0
            let maxX = lineBoxes.map(\.rect.maxX).max() ?? minX
            let maxY = lineBoxes.map(\.rect.maxY).max() ?? minY
            let rect = CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
            return LineRect(lineIndex: key, rect: rect)
        }
    }

    static func anchor(for rects: [LineRect]) -> CGPoint? {
        guard let firstRect = rects.first?.rect else {
            return nil
        }

        return CGPoint(x: firstRect.midX, y: firstRect.minY)
    }

    static func strokeHitsCharacterBox(points: [CGPoint], box: CharacterBox, padding: CGFloat = WhiteboardConstants.markHitPadding) -> Bool {
        guard !points.isEmpty else {
            return false
        }

        let targetRect = box.rect.insetBy(dx: -padding, dy: -padding)
        if points.contains(where: { targetRect.contains($0) }) {
            return true
        }

        for index in 1..<points.count {
            if segment(points[index - 1], intersects: targetRect, to: points[index]) {
                return true
            }
        }

        return false
    }

    static func strokeIntersectsRect(points: [CGPoint], rect: CGRect, padding: CGFloat = 0) -> Bool {
        guard !points.isEmpty else {
            return false
        }

        let targetRect = rect.insetBy(dx: -padding, dy: -padding)
        if points.contains(where: { targetRect.contains($0) }) {
            return true
        }

        for index in 1..<points.count {
            if segment(points[index - 1], intersects: targetRect, to: points[index]) {
                return true
            }
        }

        return false
    }

    private static func fontSupportsSampleText(_ fontName: String) -> Bool {
        guard let font = UIFont(name: fontName, size: WhiteboardConstants.defaultFontSize) else {
            return false
        }
        let sampleCharacters = Array("白板高亮中文笔记".utf16)
        var glyphs = Array(repeating: CGGlyph(), count: sampleCharacters.count)
        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        return CTFontGetGlyphsForCharacters(ctFont, sampleCharacters, &glyphs, sampleCharacters.count)
            && glyphs.allSatisfy { $0 != 0 }
    }

    private static func fontSupportsLatinSampleText(_ fontName: String) -> Bool {
        guard let font = UIFont(name: fontName, size: WhiteboardConstants.defaultFontSize) else {
            return false
        }
        let sampleCharacters = Array("Edu Whiteboard handwritten notes".utf16)
        var glyphs = Array(repeating: CGGlyph(), count: sampleCharacters.count)
        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        return CTFontGetGlyphsForCharacters(ctFont, sampleCharacters, &glyphs, sampleCharacters.count)
            && glyphs.allSatisfy { $0 != 0 }
    }

    private static func fontDescriptor(named fontName: String, size: CGFloat) -> UIFontDescriptor {
        if let uiFont = UIFont(name: fontName, size: size) {
            return uiFont.fontDescriptor
        }

        let ctFont = CTFontCreateWithName(fontName as CFString, size, nil)
        return CTFontCopyFontDescriptor(ctFont) as UIFontDescriptor
    }

    private static func strokeBoundingRect(points: [CGPoint], padding: CGFloat) -> CGRect {
        points.reduce(into: CGRect.null) { partial, point in
            let pointRect = CGRect(x: point.x, y: point.y, width: 0, height: 0)
            partial = partial.isNull ? pointRect : partial.union(pointRect)
        }
        .insetBy(dx: -padding, dy: -padding * 0.7)
    }

    private static func segment(_ start: CGPoint, intersects rect: CGRect, to end: CGPoint) -> Bool {
        if rect.intersects(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))) == false && !rect.contains(start) && !rect.contains(end) {
            return false
        }

        if rect.contains(start) || rect.contains(end) {
            return true
        }

        let edges = [
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)),
        ]

        return edges.contains { edge in
            segmentsIntersect(start, end, edge.0, edge.1)
        }
    }

    private static func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        let abC = direction(a, b, c)
        let abD = direction(a, b, d)
        let cdA = direction(c, d, a)
        let cdB = direction(c, d, b)

        if ((abC > 0 && abD < 0) || (abC < 0 && abD > 0)) && ((cdA > 0 && cdB < 0) || (cdA < 0 && cdB > 0)) {
            return true
        }

        if abC == 0 && onSegment(a, b, c) { return true }
        if abD == 0 && onSegment(a, b, d) { return true }
        if cdA == 0 && onSegment(c, d, a) { return true }
        if cdB == 0 && onSegment(c, d, b) { return true }

        return false
    }

    private static func direction(_ start: CGPoint, _ end: CGPoint, _ point: CGPoint) -> CGFloat {
        (point.x - start.x) * (end.y - start.y) - (point.y - start.y) * (end.x - start.x)
    }

    private static func onSegment(_ start: CGPoint, _ end: CGPoint, _ point: CGPoint) -> Bool {
        point.x >= min(start.x, end.x)
            && point.x <= max(start.x, end.x)
            && point.y >= min(start.y, end.y)
            && point.y <= max(start.y, end.y)
    }
}