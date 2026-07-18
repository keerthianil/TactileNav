// PortlandMapData.swift
// TactileNav
//
// Portland map feature models.
// Uses a 0-1000 designer grid with Y-flip (verticalFlipSum = 1320)
// and converts to tiny lat/lon offsets for MKMapView display.

import UIKit
import MapKit
import CoreHaptics
import TactileMapCore
import TactileMapFeedback

// MARK: - Physical Dimensions Bridge

/// Bridge to TactileMapKit's PhysicalDimensions (full device PPI database).
enum PortlandPhysicalDimensions {
    static func mmToPoints(_ mm: CGFloat) -> CGFloat {
        return PhysicalDimensions.mmToPoints(mm)
    }
}

// MARK: - Map Feature Protocol

/// Protocol for all Portland map features.
protocol PortlandMapFeature: AnyObject {
    var featureId: String { get }
    var featureType: PortlandFeatureType { get }
    var featureName: String { get }
    var level: Int { get }

    func addToMap(_ mapView: MKMapView)
    func removeFromMap(_ mapView: MKMapView)
    func startHapticFeedback(with engine: CHHapticEngine?)
    func stopHapticFeedback()
    func announcement() -> String
}

enum PortlandFeatureType: String {
    case corridor
    case intersection
    case landmark
    case sidewalk
    case crosswalk
}

// MARK: - Y-Flip Constant

private let kVerticalFlipSum: Double = 1320.0
private let kCoordScale: Double = 100000.0

/// Converts a designer grid coordinate to CLLocationCoordinate2D.
/// - Parameters:
///   - x: X value in 0–1000 grid
///   - y: Y value in 0–1000 grid (already stretched if Level 1)
func portlandGridToCoordinate(x: Double, y: Double) -> CLLocationCoordinate2D {
    let lat = (kVerticalFlipSum - y) / kCoordScale
    let lon = x / kCoordScale
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
}

// MARK: - PortlandCorridor

/// A road segment rendered as an MKPolyline overlay.
final class PortlandCorridor: NSObject, PortlandMapFeature, MKOverlay {

    let featureId: String
    let featureType: PortlandFeatureType = .corridor
    let featureName: String
    let level: Int
    let accessible: Bool

    private let coordinates: [CLLocationCoordinate2D]
    private var hapticPlayer: CHHapticPatternPlayer?

    // MKOverlay
    var coordinate: CLLocationCoordinate2D {
        return boundingMapRect.origin.coordinate
    }

    var boundingMapRect: MKMapRect {
        var rect = MKMapRect.null
        for coord in coordinates {
            let point = MKMapPoint(coord)
            let pointRect = MKMapRect(x: point.x, y: point.y, width: 0.001, height: 0.001)
            rect = rect.union(pointRect)
        }
        // Expand slightly for line width
        return rect.insetBy(dx: -0.001, dy: -0.001)
    }

    /// The polyline for rendering on the map.
    lazy var polyline: MKPolyline = {
        var coords = coordinates
        return MKPolyline(coordinates: &coords, count: coords.count)
    }()

    init(id: String, name: String, level: Int, accessible: Bool, coordinates: [CLLocationCoordinate2D]) {
        self.featureId = id
        self.featureName = name
        self.level = level
        self.accessible = accessible
        self.coordinates = coordinates
        super.init()
    }

    func addToMap(_ mapView: MKMapView) {
        mapView.addOverlay(polyline, level: .aboveLabels)
    }

    func removeFromMap(_ mapView: MKMapView) {
        mapView.removeOverlay(polyline)
    }

    func announcement() -> String {
        return featureName
    }

    // Heavy continuous buzz: intensity 1.0, sharpness 0.1
    func startHapticFeedback(with engine: CHHapticEngine?) {
        guard let engine = engine else { return }
        do {
            let pattern = try CHHapticPattern(events: [
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1)
                    ],
                    relativeTime: 0,
                    duration: 30.0
                )
            ], parameters: [])
            hapticPlayer = try engine.makePlayer(with: pattern)
            try hapticPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics unavailable
        }
    }

    func stopHapticFeedback() {
        try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        hapticPlayer = nil
    }

    /// Returns all CLLocationCoordinate2D points for hit testing.
    func getCoordinates() -> [CLLocationCoordinate2D] {
        return coordinates
    }
}

// MARK: - PortlandIntersection

/// An intersection point rendered as an MKAnnotation.
final class PortlandIntersection: NSObject, PortlandMapFeature, MKAnnotation, Identifiable {

    var id: String { featureId }

    let featureId: String
    let featureType: PortlandFeatureType = .intersection
    let featureName: String
    let level: Int
    let ways: Int
    let hasAPS: Bool
    let signalized: Bool
    let crossingComplexity: String

    private var hapticPlayer: CHHapticPatternPlayer?

    // MKAnnotation
    let coordinate: CLLocationCoordinate2D
    var title: String? { return featureName }

    init(id: String, name: String, level: Int, coordinate: CLLocationCoordinate2D,
         ways: Int = 4, hasAPS: Bool = false, signalized: Bool = false,
         crossingComplexity: String = "moderate") {
        self.featureId = id
        self.featureName = name
        self.level = level
        self.coordinate = coordinate
        self.ways = ways
        self.hasAPS = hasAPS
        self.signalized = signalized
        self.crossingComplexity = crossingComplexity
        super.init()
    }

    func addToMap(_ mapView: MKMapView) {
        mapView.addAnnotation(self)
    }

    func removeFromMap(_ mapView: MKMapView) {
        mapView.removeAnnotation(self)
    }

    func announcement() -> String {
        let wayDesc: String
        switch ways {
        case 3: wayDesc = "3-way"
        case 4: wayDesc = "4-way"
        default: wayDesc = "\(ways)-way"
        }
        return "\(wayDesc) intersection, \(featureName)"
    }

    // Pulsing haptic: 0.25s interval, 0.15s duration, intensity 1.0, sharpness 0.5
    func startHapticFeedback(with engine: CHHapticEngine?) {
        guard let engine = engine else { return }
        do {
            var events: [CHHapticEvent] = []
            let pulseDuration: TimeInterval = 0.15
            let pulseInterval: TimeInterval = 0.25
            let totalDuration: TimeInterval = 30.0
            var time: TimeInterval = 0
            while time < totalDuration {
                events.append(CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                    ],
                    relativeTime: time,
                    duration: pulseDuration
                ))
                time += pulseInterval
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            hapticPlayer = try engine.makePlayer(with: pattern)
            try hapticPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics unavailable
        }
    }

    func stopHapticFeedback() {
        try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        hapticPlayer = nil
    }
}

// MARK: - Intersection Annotation View

/// Red square annotation view for intersections (6mm side, white border).
final class PortlandIntersectionAnnotationView: MKAnnotationView {

    static let reuseIdentifier = "PortlandIntersection"

    private let trafficLightDot = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }

    private func setup() {
        let side = PortlandPhysicalDimensions.mmToPoints(6.0)
        let borderWidth = PortlandPhysicalDimensions.mmToPoints(0.5)

        frame = CGRect(x: 0, y: 0, width: side, height: side)
        centerOffset = CGPoint(x: 0, y: 0)

        backgroundColor = UIColor(red: 0xC1/255.0, green: 0x12/255.0, blue: 0x1F/255.0, alpha: 1.0)
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = borderWidth

        let dotSize: CGFloat = 8
        trafficLightDot.frame = CGRect(x: side - dotSize / 2, y: -dotSize / 2, width: dotSize, height: dotSize)
        trafficLightDot.backgroundColor = .systemGreen
        trafficLightDot.layer.cornerRadius = dotSize / 2
        trafficLightDot.layer.borderColor = UIColor.white.cgColor
        trafficLightDot.layer.borderWidth = 1
        trafficLightDot.isHidden = true
        addSubview(trafficLightDot)

        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    func showTrafficLight(_ visible: Bool) {
        trafficLightDot.isHidden = !visible
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setup()
    }
}

// MARK: - PortlandLandmark

/// A landmark point rendered as an MKAnnotation with a purple tag box.
final class PortlandLandmark: NSObject, PortlandMapFeature, MKAnnotation {

    let featureId: String
    let featureType: PortlandFeatureType = .landmark
    let featureName: String
    let level: Int
    let tag: String
    let side: String
    let announcementText: String
    let category: String

    private var hapticPlayer: CHHapticPatternPlayer?

    // MKAnnotation
    let coordinate: CLLocationCoordinate2D
    var title: String? { return featureName }

    init(id: String, name: String, level: Int, coordinate: CLLocationCoordinate2D,
         tag: String, side: String, announcement: String, category: String) {
        self.featureId = id
        self.featureName = name
        self.level = level
        self.coordinate = coordinate
        self.tag = tag
        self.side = side
        self.announcementText = announcement
        self.category = category
        super.init()
    }

    func addToMap(_ mapView: MKMapView) {
        mapView.addAnnotation(self)
    }

    func removeFromMap(_ mapView: MKMapView) {
        mapView.removeAnnotation(self)
    }

    func announcement() -> String {
        return announcementText
    }

    // Fast pulse: 0.12s interval, 0.08s duration, intensity 1.0, sharpness 0.7
    func startHapticFeedback(with engine: CHHapticEngine?) {
        guard let engine = engine else { return }
        do {
            var events: [CHHapticEvent] = []
            let pulseDuration: TimeInterval = 0.08
            let pulseInterval: TimeInterval = 0.12
            let totalDuration: TimeInterval = 30.0
            var time: TimeInterval = 0
            while time < totalDuration {
                events.append(CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
                    ],
                    relativeTime: time,
                    duration: pulseDuration
                ))
                time += pulseInterval
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            hapticPlayer = try engine.makePlayer(with: pattern)
            try hapticPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics unavailable
        }
    }

    func stopHapticFeedback() {
        try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        hapticPlayer = nil
    }
}

// MARK: - Landmark Annotation View

/// Purple box annotation view for landmarks (9x6mm, tag label, white border).
final class PortlandLandmarkAnnotationView: MKAnnotationView {

    static let reuseIdentifier = "PortlandLandmark"

    private let tagLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }

    private func setup() {
        let width = PortlandPhysicalDimensions.mmToPoints(9.0)
        let height = PortlandPhysicalDimensions.mmToPoints(6.0)
        let borderWidth = PortlandPhysicalDimensions.mmToPoints(0.5)

        frame = CGRect(x: 0, y: 0, width: width, height: height)

        backgroundColor = UIColor(red: 0x7B/255.0, green: 0x2C/255.0, blue: 0xBF/255.0, alpha: 1.0) // #7b2cbf
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = borderWidth

        tagLabel.textColor = .white
        tagLabel.font = UIFont.systemFont(ofSize: 9, weight: .bold)
        tagLabel.textAlignment = .center
        tagLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tagLabel)

        NSLayoutConstraint.activate([
            tagLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            tagLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2)
        ])

        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    override var annotation: MKAnnotation? {
        didSet {
            if let landmark = annotation as? PortlandLandmark {
                tagLabel.text = landmark.tag
                // Offset to side of road
                let offsetX = PortlandPhysicalDimensions.mmToPoints(landmark.side == "left" ? -6.0 : 6.0)
                centerOffset = CGPoint(x: offsetX, y: 0)
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setup()
    }
}

// MARK: - PortlandSidewalk

/// A sidewalk line rendered as a gray overlay.
final class PortlandSidewalk: NSObject, PortlandMapFeature, MKOverlay {

    let featureId: String
    let featureType: PortlandFeatureType = .sidewalk
    let featureName: String
    let level: Int

    private let coordinates: [CLLocationCoordinate2D]
    private var hapticPlayer: CHHapticPatternPlayer?

    var coordinate: CLLocationCoordinate2D {
        return boundingMapRect.origin.coordinate
    }

    var boundingMapRect: MKMapRect {
        var rect = MKMapRect.null
        for coord in coordinates {
            let point = MKMapPoint(coord)
            let pointRect = MKMapRect(x: point.x, y: point.y, width: 0.001, height: 0.001)
            rect = rect.union(pointRect)
        }
        return rect.insetBy(dx: -0.001, dy: -0.001)
    }

    lazy var polyline: MKPolyline = {
        var coords = coordinates
        return MKPolyline(coordinates: &coords, count: coords.count)
    }()

    init(id: String, name: String, level: Int, coordinates: [CLLocationCoordinate2D]) {
        self.featureId = id
        self.featureName = name
        self.level = level
        self.coordinates = coordinates
        super.init()
    }

    func addToMap(_ mapView: MKMapView) {
        mapView.addOverlay(polyline, level: .aboveLabels)
    }

    func removeFromMap(_ mapView: MKMapView) {
        mapView.removeOverlay(polyline)
    }

    func announcement() -> String {
        return featureName
    }

    // Softer continuous: intensity 0.78, sharpness 0.78
    func startHapticFeedback(with engine: CHHapticEngine?) {
        guard let engine = engine else { return }
        do {
            let pattern = try CHHapticPattern(events: [
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.78),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.78)
                    ],
                    relativeTime: 0,
                    duration: 30.0
                )
            ], parameters: [])
            hapticPlayer = try engine.makePlayer(with: pattern)
            try hapticPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics unavailable
        }
    }

    func stopHapticFeedback() {
        try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        hapticPlayer = nil
    }

    func getCoordinates() -> [CLLocationCoordinate2D] {
        return coordinates
    }
}

// MARK: - PortlandCrosswalk

/// A crosswalk rendered as a white dashed overlay.
final class PortlandCrosswalk: NSObject, PortlandMapFeature, MKOverlay {

    let featureId: String
    let featureType: PortlandFeatureType = .crosswalk
    let featureName: String
    let level: Int

    private let coordinates: [CLLocationCoordinate2D]
    private var hapticPlayer: CHHapticPatternPlayer?

    var coordinate: CLLocationCoordinate2D {
        return boundingMapRect.origin.coordinate
    }

    var boundingMapRect: MKMapRect {
        var rect = MKMapRect.null
        for coord in coordinates {
            let point = MKMapPoint(coord)
            let pointRect = MKMapRect(x: point.x, y: point.y, width: 0.001, height: 0.001)
            rect = rect.union(pointRect)
        }
        return rect.insetBy(dx: -0.001, dy: -0.001)
    }

    lazy var polyline: MKPolyline = {
        var coords = coordinates
        return MKPolyline(coordinates: &coords, count: coords.count)
    }()

    init(id: String, name: String, level: Int, coordinates: [CLLocationCoordinate2D]) {
        self.featureId = id
        self.featureName = name
        self.level = level
        self.coordinates = coordinates
        super.init()
    }

    func addToMap(_ mapView: MKMapView) {
        mapView.addOverlay(polyline, level: .aboveLabels)
    }

    func removeFromMap(_ mapView: MKMapView) {
        mapView.removeOverlay(polyline)
    }

    func announcement() -> String {
        return featureName
    }

    // Rapid transient ticks: 0.17s interval, intensity 1.0, sharpness 1.0
    func startHapticFeedback(with engine: CHHapticEngine?) {
        guard let engine = engine else { return }
        do {
            var events: [CHHapticEvent] = []
            let tickInterval: TimeInterval = 0.17
            let totalDuration: TimeInterval = 30.0
            var time: TimeInterval = 0
            while time < totalDuration {
                events.append(CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ],
                    relativeTime: time
                ))
                time += tickInterval
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            hapticPlayer = try engine.makePlayer(with: pattern)
            try hapticPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics unavailable
        }
    }

    func stopHapticFeedback() {
        try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        hapticPlayer = nil
    }

    func getCoordinates() -> [CLLocationCoordinate2D] {
        return coordinates
    }
}

// MARK: - APS Location

struct PortlandAPSLocation: Codable {
    let id: String
    let location: String
    let intersectionId: String
    let signalType: String
    let hasVibrotactile: Bool
    let hasPushButton: Bool
    let notes: String?
}

// MARK: - Traffic Data

struct PortlandTrafficSegment: Codable {
    let id: String
    let name: String
    let lanes: Int
    let aadt: Int
    let speedLimit: Int?
    let hourlyProfile: [String: HourlyProfile]

    struct HourlyProfile: Codable {
        let level: String
        let pctOfAadt: Double?

        enum CodingKeys: String, CodingKey {
            case level
            case pctOfAadt = "pct_of_aadt"
        }
    }
}

struct PortlandTrafficIntersection: Codable {
    let id: String
    let signalized: Bool
    let hasTrafficLight: Bool?
}

// MARK: - Traffic Time of Day

enum TrafficTimeOfDay: String, CaseIterable, Identifiable {
    case morningRush = "morning_rush"
    case midday = "midday"
    case eveningRush = "evening_rush"
    case evening = "evening"
    case night = "night"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .morningRush: return "Morning Rush"
        case .midday: return "Midday"
        case .eveningRush: return "Evening Rush"
        case .evening: return "Evening"
        case .night: return "Night"
        }
    }

    var shortLabel: String {
        switch self {
        case .morningRush: return "AM"
        case .midday: return "Mid"
        case .eveningRush: return "PM"
        case .evening: return "Eve"
        case .night: return "Night"
        }
    }

    var description: String {
        switch self {
        case .morningRush: return "7 AM to 9 AM, peak commute hours"
        case .midday: return "10 AM to 3 PM, moderate traffic"
        case .eveningRush: return "4 PM to 6 PM, peak commute hours"
        case .evening: return "7 PM to 10 PM, lighter traffic"
        case .night: return "11 PM to 6 AM, very light traffic"
        }
    }
}
