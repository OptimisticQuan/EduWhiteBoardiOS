import SwiftUI
import XCTest
@testable import EduWhiteBoardiOS

final class EduWhiteBoardiOSTests: XCTestCase {
    func testScreenLayoutUsesSymmetricChromePadding() {
        XCTAssertEqual(WhiteboardScreenLayout.horizontalInset(for: 402), 12)
        XCTAssertEqual(WhiteboardScreenLayout.horizontalInset(for: 259), 12)
    }

    func testWideScreenLayoutUsesSmallMarginsInsteadOfCappedContentFrame() {
        XCTAssertEqual(WhiteboardScreenLayout.horizontalInset(for: 800), 18)
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
