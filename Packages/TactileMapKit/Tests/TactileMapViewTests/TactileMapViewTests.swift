import XCTest
@testable import TactileMapView
@testable import TactileMapCore

final class TactileMapViewTests: XCTestCase {

    // MARK: - Configuration Tests

    func testDefaultConfiguration() {
        let config = TactileMapViewConfiguration.default
        XCTAssertEqual(config.corridorLineWidthMM, 4.0)
        XCTAssertEqual(config.intersectionDiameterMM, 8.0)
        XCTAssertEqual(config.landmarkWidthMM, 6.0)
        XCTAssertEqual(config.landmarkHeightMM, 4.0)
        XCTAssertEqual(config.anchorPointDiameterMM, 8.0)
        XCTAssertEqual(config.longPressMinDuration, 0.1)
        XCTAssertTrue(config.isVoiceOverBackGestureEnabled)
    }

    func testCustomConfiguration() {
        let config = TactileMapViewConfiguration(
            corridorColor: .systemGreen,
            corridorLineWidthMM: 6.0,
            intersectionDiameterMM: 10.0
        )
        XCTAssertEqual(config.corridorLineWidthMM, 6.0)
        XCTAssertEqual(config.intersectionDiameterMM, 10.0)
    }

    // MARK: - HitDetection Config Tests

    func testDefaultHitDetection() {
        let config = HitDetectionConfig.default
        XCTAssertEqual(config.anchorHitRadiusPts, 20)
        XCTAssertEqual(config.pointHitRadiusPts, 25)
        XCTAssertEqual(config.corridorBaseRadiusPts, 20)
        XCTAssertEqual(config.velocityBonusMax, 30)
        XCTAssertEqual(config.updateThreshold, 0.1)
    }
}
