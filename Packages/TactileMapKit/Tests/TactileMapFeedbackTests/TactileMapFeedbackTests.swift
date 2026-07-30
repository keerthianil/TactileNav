import XCTest
import TactileMapCore
@testable import TactileMapFeedback

final class TactileMapFeedbackTests: XCTestCase {

    // MARK: - HapticPattern Tests

    func testCorridorPreset() {
        let pattern = HapticPattern.corridorContinuous
        XCTAssertEqual(pattern.intensity, 1.0)
        XCTAssertEqual(pattern.sharpness, 0.5)
        if case .continuous(let duration) = pattern.mode {
            XCTAssertEqual(duration, 100.0)
        } else {
            XCTFail("Corridor should use continuous mode")
        }
    }

    func testIntersectionPreset() {
        let pattern = HapticPattern.intersectionPulse
        XCTAssertEqual(pattern.intensity, 1.0)
        if case .pulsing(let on, let off, let count) = pattern.mode {
            XCTAssertEqual(on, 0.15)
            XCTAssertEqual(off, 0.10)
            XCTAssertEqual(count, 20)
        } else {
            XCTFail("Intersection should use pulsing mode")
        }
    }

    func testLandmarkPreset() {
        let pattern = HapticPattern.landmarkFastPulse
        XCTAssertEqual(pattern.intensity, 1.0)
        XCTAssertEqual(pattern.sharpness, 0.7)
        if case .pulsing(let on, let off, let count) = pattern.mode {
            XCTAssertEqual(on, 0.08)
            XCTAssertEqual(off, 0.04)
            XCTAssertEqual(count, 80)
        } else {
            XCTFail("Landmark should use fast pulsing mode")
        }
    }

    func testSingleTapPreset() {
        let pattern = HapticPattern.singleTap
        if case .transient = pattern.mode {
            // Pass
        } else {
            XCTFail("Single tap should use transient mode")
        }
    }

    func testCustomPattern() {
        let custom = HapticPattern(
            intensity: 0.5,
            sharpness: 0.8,
            mode: .pulsing(onDuration: 0.2, offDuration: 0.3, count: 10)
        )
        XCTAssertEqual(custom.intensity, 0.5)
        XCTAssertEqual(custom.sharpness, 0.8)
    }

    func testBurstPattern() {
        let burst = HapticPattern(
            intensity: 1.0,
            sharpness: 0.8,
            mode: .burst(pulseCount: 3, onDuration: 0.25, offDuration: 0.4)
        )
        XCTAssertEqual(burst.intensity, 1.0)
        XCTAssertEqual(burst.sharpness, 0.8)
        if case .burst(let pulseCount, let on, let off) = burst.mode {
            XCTAssertEqual(pulseCount, 3)
            XCTAssertEqual(on, 0.25)
            XCTAssertEqual(off, 0.4)
        } else {
            XCTFail("Pattern should use burst mode")
        }
    }

    // MARK: - Outdoor element types

    func testOutdoorElementTypeRawValues() {
        XCTAssertEqual(TactileElementType.crosswalk.rawValue, "crosswalk")
        XCTAssertEqual(TactileElementType.route.rawValue, "route")
        XCTAssertEqual(TactileElementType.street.rawValue, "street")
        XCTAssertEqual(TactileElementType.road.rawValue, "road")
    }
}
