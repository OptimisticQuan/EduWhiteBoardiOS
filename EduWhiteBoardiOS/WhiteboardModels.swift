import Foundation
import SwiftUI

enum WhiteboardTool: String, CaseIterable, Codable {
    case select
    case highlight
    case erase

    var title: String {
        switch self {
        case .select:
            return "选择"
        case .highlight:
            return "高亮"
        case .erase:
            return "橡皮擦"
        }
    }

    var systemImage: String {
        switch self {
        case .select:
            return "cursorarrow"
        case .highlight:
            return "highlighter"
        case .erase:
            return "eraser"
        }
    }
}

enum HighlightColorToken: String, CaseIterable, Codable {
    case yellow
    case blue
    case green
    case purple
    case pink

    var fillColor: Color {
        switch self {
        case .yellow:
            return Color(red: 1.0, green: 0.82, blue: 0.28).opacity(0.68)
        case .blue:
            return Color(red: 0.44, green: 0.77, blue: 1.0).opacity(0.62)
        case .green:
            return Color(red: 0.50, green: 0.85, blue: 0.55).opacity(0.66)
        case .purple:
            return Color(red: 0.74, green: 0.63, blue: 1.0).opacity(0.62)
        case .pink:
            return Color(red: 1.0, green: 0.58, blue: 0.74).opacity(0.64)
        }
    }

    var accentColor: Color {
        switch self {
        case .yellow:
            return Color(red: 0.85, green: 0.60, blue: 0.00)
        case .blue:
            return Color(red: 0.12, green: 0.50, blue: 0.79)
        case .green:
            return Color(red: 0.18, green: 0.60, blue: 0.27)
        case .purple:
            return Color(red: 0.48, green: 0.36, blue: 0.90)
        case .pink:
            return Color(red: 0.85, green: 0.31, blue: 0.53)
        }
    }
}

struct BoardPoint: Codable, Hashable {
    var x: CGFloat
    var y: CGFloat

    static let zero = BoardPoint(x: 0, y: 0)

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

struct BoardSize: Codable, Hashable {
    var width: CGFloat
    var height: CGFloat

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    init(_ size: CGSize) {
        width = size.width
        height = size.height
    }

    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

struct TextAnnotation: Identifiable, Codable, Hashable {
    var id = UUID()
    var start: Int
    var end: Int
    var color: HighlightColorToken
    var alias: String?
    var createdAt = Date()
    var updatedAt = Date()
}

struct WhiteboardTextCard: Identifiable, Codable, Hashable {
    var id = UUID()
    var center: BoardPoint
    var size: BoardSize
    var text: String
    var annotations: [TextAnnotation] = []
    var fontSize: CGFloat = WhiteboardConstants.defaultFontSize
    var lineHeight: CGFloat = WhiteboardConstants.defaultLineHeight
}

struct WhiteboardDocument: Codable, Hashable {
    var items: [WhiteboardTextCard]
    var selectedItemID: UUID?
    var cameraOffset: BoardPoint
    var zoom: CGFloat
    var highlightCursor: Int
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

enum ClearCanvasResult: Equatable {
    case armed
    case alreadyEmpty
    case cleared(Int)
}

enum WhiteboardPalette {
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.91)
    static let panel = Color.white.opacity(0.90)
    static let panelBorder = Color.white.opacity(0.72)
    static let ink = Color(red: 0.07, green: 0.13, blue: 0.23)
    static let inkMuted = Color(red: 0.24, green: 0.30, blue: 0.40)
    static let coral = Color(red: 0.98, green: 0.48, blue: 0.35)
    static let lake = Color(red: 0.24, green: 0.63, blue: 0.73)
    static let grid = Color(red: 0.11, green: 0.17, blue: 0.27).opacity(0.08)
}

enum WhiteboardConstants {
    static let textPadding: CGFloat = 20
    static let defaultFontSize: CGFloat = 32
    static let defaultLineHeight: CGFloat = 1.38
    static let defaultCardWidth: CGFloat = 420
    static let minimumCardWidth: CGFloat = 240
    static let singleLineCardHeight = ceil(defaultFontSize * defaultLineHeight + textPadding * 2 + 8)
    static let defaultCardHeight: CGFloat = singleLineCardHeight
    static let minimumCardHeight: CGFloat = singleLineCardHeight
    static let minZoom: CGFloat = 0.55
    static let maxZoom: CGFloat = 2.8
    static let markHitPadding: CGFloat = 6
    static let aliasOptions = ["A", "B", "C", "D", "E", "F"]
    static let asrMaxWidthRatio: CGFloat = 0.82
    static let documentStorageKey = "edu-whiteboard.native.document"
}

enum WhiteboardScreenLayout {
    static let verticalSpacing: CGFloat = 8
    static let voiceBottomInset: CGFloat = 8

    static func horizontalInset(for viewportWidth: CGFloat) -> CGFloat {
        viewportWidth >= 700 ? 18 : 12
    }
}

enum WhiteboardCanvasGeometry {
    static func screenPoint(item: WhiteboardTextCard, localPoint: CGPoint, zoom: CGFloat, cameraOffset: CGSize) -> CGPoint {
        let cardLeft = item.center.x - item.size.width / 2
        let cardTop = item.center.y - item.size.height / 2
        return CGPoint(
            x: (cardLeft + localPoint.x) * zoom + cameraOffset.width,
            y: (cardTop + localPoint.y) * zoom + cameraOffset.height
        )
    }

    static func badgeCenter(for anchorScreenPoint: CGPoint, badgeSize: CGFloat, gap: CGFloat) -> CGPoint {
        CGPoint(
            x: anchorScreenPoint.x,
            y: anchorScreenPoint.y - badgeSize / 2 - gap
        )
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
