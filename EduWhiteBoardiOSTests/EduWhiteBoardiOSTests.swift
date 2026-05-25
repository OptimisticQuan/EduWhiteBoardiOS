import SwiftUI
import XCTest
@testable import EduWhiteBoardiOS

final class EduWhiteBoardiOSTests: XCTestCase {
    func testScreenLayoutKeepsCanvasSymmetricAndNearBottom() {
        let metrics = WhiteboardScreenLayout.metrics(
            viewportSize: CGSize(width: 393, height: 852),
            safeAreaInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        )

        XCTAssertEqual(metrics.horizontalInset, 12)
        XCTAssertEqual(metrics.canvasFrame.minX, 12)
        XCTAssertEqual(metrics.canvasFrame.maxX, 381)
        XCTAssertEqual(metrics.canvasFrame.maxY, 818)
        XCTAssertLessThan(metrics.canvasFrame.minY, 180)
    }

    func testCompactScreenLayoutKeepsEqualHorizontalMargins() {
        let metrics = WhiteboardScreenLayout.metrics(
            viewportSize: CGSize(width: 259, height: 568),
            safeAreaInsets: EdgeInsets(top: 47, leading: 0, bottom: 21, trailing: 0)
        )

        XCTAssertEqual(metrics.canvasFrame.minX, metrics.horizontalInset)
        XCTAssertEqual(metrics.canvasFrame.maxX, 259 - metrics.horizontalInset)
    }

    func testBadgeCenterCanMoveOutsideCanvasForClipping() {
        let badgeCenter = WhiteboardCanvasGeometry.badgeCenter(
            for: CGPoint(x: -35, y: -10),
            badgeSize: 46,
            gap: 14
        )

        XCTAssertLessThan(badgeCenter.x, 0)
        XCTAssertLessThan(badgeCenter.y, 0)
    }
}
