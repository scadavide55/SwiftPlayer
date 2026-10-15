import XCTest
@testable import SwiftPlayer

final class PlaybackRateFormattingTests: XCTestCase {
    func testSpeedLabelsRetainQuarterSteps() {
        XCTAssertEqual(formatPlaybackRate(1.25), "1.25×")
        XCTAssertEqual(formatPlaybackRate(0.75), "0.75×")
        XCTAssertEqual(formatPlaybackRate(1), "1×")
        XCTAssertEqual(formatPlaybackRate(4), "4×")
    }
}
