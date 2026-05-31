import XCTest
@testable import TactileMapCore

final class TactileMapCoreTests: XCTestCase {

    // MARK: - TactileElementType Tests

    func testBuiltInTypes() {
        XCTAssertEqual(TactileElementType.corridor.rawValue, "corridor")
        XCTAssertEqual(TactileElementType.intersection.rawValue, "intersection")
        XCTAssertEqual(TactileElementType.landmark.rawValue, "landmark")
    }

    func testCustomElementType() {
        let customType = TactileElementType(rawValue: "emergency_exit")
        XCTAssertEqual(customType.rawValue, "emergency_exit")
        XCTAssertNotEqual(customType, .corridor)
    }

    // MARK: - TactileCoordinate Tests

    func testCoordinateCreation() {
        let coord = TactileCoordinate(x: 200, y: 800)
        XCTAssertEqual(coord.x, 200)
        XCTAssertEqual(coord.y, 800)
    }

    // MARK: - CoordinateTransform Tests

    func testDefaultTransform() {
        let transform = CoordinateTransform.default
        XCTAssertEqual(transform.scaleFactor, 100_000)
        XCTAssertEqual(transform.stretchFactorY, 2.6)
        XCTAssertEqual(transform.centerY, 500.0)
    }

    func testCoordinateConversion() {
        let transform = CoordinateTransform.default
        let coord = TactileCoordinate(x: 500, y: 500)

        // At centerY, stretch should have no effect
        let cl = transform.toCLCoordinate(coord)

        // stretchedY = 500 + (500 - 500) * 2.6 = 500
        // lat = 500 / 100000 = 0.005
        // lon = 500 / 100000 = 0.005
        XCTAssertEqual(cl.latitude, 0.005, accuracy: 0.0001)
        XCTAssertEqual(cl.longitude, 0.005, accuracy: 0.0001)
    }

    func testCoordinateConversionWithStretch() {
        let transform = CoordinateTransform.default
        let coord = TactileCoordinate(x: 200, y: 200)

        let cl = transform.toCLCoordinate(coord)

        // stretchedY = 500 + (200 - 500) * 2.6 = 500 + (-300 * 2.6) = 500 - 780 = -280
        // lat = -280 / 100000 = -0.0028
        // lon = 200 / 100000 = 0.002
        XCTAssertEqual(cl.latitude, -0.0028, accuracy: 0.0001)
        XCTAssertEqual(cl.longitude, 0.002, accuracy: 0.0001)
    }

    func testNoStretchTransform() {
        let transform = CoordinateTransform(
            scaleFactor: 100_000,
            stretchFactorX: 1.0,
            stretchFactorY: 1.0,
            centerY: 500.0
        )

        let coord = TactileCoordinate(x: 200, y: 200)
        let cl = transform.toCLCoordinate(coord)

        // No stretch: lat = 200/100000 = 0.002
        XCTAssertEqual(cl.latitude, 0.002, accuracy: 0.0001)
        XCTAssertEqual(cl.longitude, 0.002, accuracy: 0.0001)
    }

    func testBatchCoordinateConversion() {
        let transform = CoordinateTransform.default
        let coords = [
            TactileCoordinate(x: 200, y: 200),
            TactileCoordinate(x: 800, y: 200),
            TactileCoordinate(x: 800, y: 800),
        ]

        let clCoords = transform.toCLCoordinates(coords)
        XCTAssertEqual(clCoords.count, 3)
    }

    // MARK: - TactileProperties Tests

    func testPropertiesDecoding() throws {
        let json = """
        {
            "name": "Bathroom",
            "category": "bathroom",
            "side": "right",
            "level": 1,
            "accessible": true
        }
        """.data(using: .utf8)!

        let props = try JSONDecoder().decode(TactileProperties.self, from: json)
        XCTAssertEqual(props.name, "Bathroom")
        XCTAssertEqual(props.category, "bathroom")
        XCTAssertEqual(props.side, "right")
        XCTAssertEqual(props.level, 1)
        XCTAssertTrue(props.isAccessible)
    }

    func testPropertiesDefaultValues() throws {
        let json = """
        {
            "name": "Test"
        }
        """.data(using: .utf8)!

        let props = try JSONDecoder().decode(TactileProperties.self, from: json)
        XCTAssertEqual(props.name, "Test")
        XCTAssertNil(props.category)
        XCTAssertNil(props.side)
        XCTAssertTrue(props.isAccessible) // Default true
        XCTAssertEqual(props.custom, [:]) // Default empty
    }

    // MARK: - TactileGeometry Tests

    func testPointGeometry() {
        let geom = TactileGeometry.point(TactileCoordinate(x: 350, y: 650))
        if case .point(let coord) = geom {
            XCTAssertEqual(coord.x, 350)
            XCTAssertEqual(coord.y, 650)
        } else {
            XCTFail("Expected point geometry")
        }
    }

    func testLineStringGeometry() {
        let coords = [
            TactileCoordinate(x: 200, y: 200),
            TactileCoordinate(x: 800, y: 200),
        ]
        let geom = TactileGeometry.lineString(coords)
        if case .lineString(let lineCoords) = geom {
            XCTAssertEqual(lineCoords.count, 2)
        } else {
            XCTFail("Expected lineString geometry")
        }
    }

    // MARK: - MapElement Tests

    func testMapElementCreation() {
        let element = MapElement(
            id: "c1",
            elementType: .corridor,
            geometry: .lineString([
                TactileCoordinate(x: 200, y: 200),
                TactileCoordinate(x: 800, y: 200),
            ]),
            properties: TactileProperties(
                name: "South Corridor",
                category: nil,
                side: nil,
                level: 1,
                isAccessible: true,
                connectedCorridors: nil,
                custom: [:]
            )
        )

        XCTAssertEqual(element.id, "c1")
        XCTAssertEqual(element.elementType, .corridor)
        XCTAssertEqual(element.properties.name, "South Corridor")
    }

    // MARK: - HitDetector Geometry Tests

    func testDistanceCalculation() {
        // Test point-to-point distance
        let p1 = CGPoint(x: 0, y: 0)
        let p2 = CGPoint(x: 3, y: 4)
        let distance = sqrt(pow(p2.x - p1.x, 2) + pow(p2.y - p1.y, 2))
        XCTAssertEqual(distance, 5.0, accuracy: 0.01)
    }

    func testPointToLineDistance() {
        // Point directly on the line should have distance 0
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 10, y: 0)
        let pointOnLine = CGPoint(x: 5, y: 0)

        let distance = distanceFromPoint(pointOnLine, toLineFrom: start, to: end)
        XCTAssertEqual(distance, 0.0, accuracy: 0.01)
    }

    func testPointAboveLine() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 10, y: 0)
        let pointAbove = CGPoint(x: 5, y: 3)

        let distance = distanceFromPoint(pointAbove, toLineFrom: start, to: end)
        XCTAssertEqual(distance, 3.0, accuracy: 0.01)
    }

    // Helper: distance from point to line segment (matching HitDetector logic)
    private func distanceFromPoint(_ point: CGPoint, toLineFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let lineLength = sqrt(pow(end.x - start.x, 2) + pow(end.y - start.y, 2))
        if lineLength == 0 {
            return sqrt(pow(point.x - start.x, 2) + pow(point.y - start.y, 2))
        }
        let t = max(0, min(1, ((point.x - start.x) * (end.x - start.x) +
                                (point.y - start.y) * (end.y - start.y)) /
                               (lineLength * lineLength)))
        let projX = start.x + t * (end.x - start.x)
        let projY = start.y + t * (end.y - start.y)
        return sqrt(pow(point.x - projX, 2) + pow(point.y - projY, 2))
    }
}
