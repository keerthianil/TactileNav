// PortlandMapData.swift
// TactileNav
//
// Domain models + MapKit render objects for the Congress Square tactile map.
//
// Geometry comes from `congress_square.json`, a real OpenStreetMap (ODbL) extract of
// downtown Portland, Maine, parsed by the TactileMapKit package (`TactileMapDocument`)
// and projected to CLLocationCoordinate2D by `CongressSquareAdapter`. Coordinates are
// real (metric) so distances and crossing widths are truthful; the base tiles are blank
// so only relative geometry is shown. APS and traffic point data layered on top are
// SIMULATED (see the JSON headers) but carry real-source schemas so a future data drop
// is a file swap.

import UIKit
import MapKit
import TactileMapCore

// MARK: - Physical Dimensions Bridge

/// Bridge to TactileMapKit's PhysicalDimensions (per-device PPI database) so every
/// feature is drawn at a true physical size (mm) regardless of screen density.
enum PortlandPhysicalDimensions {
    static func mmToPoints(_ mm: CGFloat) -> CGFloat { PhysicalDimensions.mmToPoints(mm) }
}

// MARK: - Feature protocol

protocol PortlandMapFeature: AnyObject {
    var featureId: String { get }
    var featureType: PortlandFeatureType { get }
    var featureName: String { get }
    var level: Int { get }
    func announcement() -> String
}

enum PortlandFeatureType: String {
    case corridor, intersection, landmark, sidewalk, crosswalk
}

// MARK: - Traffic level

/// Congestion bucket for a corridor at the selected time of day. Blind/low-vision users
/// perceive this through haptic *intensity* and an audio *rumble* (not colour); colour is
/// only a secondary cue for sighted/low-vision users.
enum TrafficLevel: String {
    case veryLight = "very_light"
    case light
    case moderate
    case heavy
    case veryHeavy = "very_heavy"

    init(raw: String) { self = TrafficLevel(rawValue: raw) ?? .moderate }

    var spoken: String {
        switch self {
        case .veryLight: return "very light"
        case .light:     return "light"
        case .moderate:  return "moderate"
        case .heavy:     return "heavy"
        case .veryHeavy: return "very heavy"
        }
    }

    /// Continuous-buzz intensity while tracing the road (heavier = stronger).
    var hapticIntensity: Float {
        switch self {
        case .veryLight: return 0.30
        case .light:     return 0.45
        case .moderate:  return 0.65
        case .heavy:     return 0.85
        case .veryHeavy: return 1.0
        }
    }

    /// Low-frequency traffic rumble; heavier traffic = lower, denser rumble.
    /// nil means "quiet enough to detect gaps" → no rumble layer.
    var rumbleHz: Double? {
        switch self {
        case .veryLight: return nil
        case .light:     return nil
        case .moderate:  return 220
        case .heavy:     return 180
        case .veryHeavy: return 140
        }
    }

    /// Seconds between rumble pulses (denser traffic = faster).
    var rumbleInterval: TimeInterval {
        switch self {
        case .veryHeavy: return 0.18
        case .heavy:     return 0.26
        default:         return 0.34
        }
    }

    var color: UIColor {
        switch self {
        case .veryLight: return UIColor(red: 0x2E/255, green: 0x7D/255, blue: 0x32/255, alpha: 1) // green
        case .light:     return UIColor(red: 0x21/255, green: 0x96/255, blue: 0xF3/255, alpha: 1) // blue
        case .moderate:  return UIColor(red: 0x02/255, green: 0x3E/255, blue: 0x8A/255, alpha: 1) // deep blue
        case .heavy:     return UIColor(red: 0xE6/255, green: 0x7E/255, blue: 0x22/255, alpha: 1) // orange
        case .veryHeavy: return UIColor(red: 0xC1/255, green: 0x12/255, blue: 0x1F/255, alpha: 1) // red
        }
    }
}

// MARK: - Corridor (road)

final class PortlandCorridor: NSObject, PortlandMapFeature {
    let featureId: String
    let featureType: PortlandFeatureType = .corridor
    let featureName: String
    let level: Int
    let accessible: Bool
    let functionalClass: String
    let lanes: Int
    let oneway: Bool
    let crossingDistanceM: Double

    private let coordinates: [CLLocationCoordinate2D]

    lazy var polyline: MKPolyline = {
        var c = coordinates
        return MKPolyline(coordinates: &c, count: c.count)
    }()

    init(id: String, name: String, level: Int, accessible: Bool,
         coordinates: [CLLocationCoordinate2D],
         functionalClass: String = "residential", lanes: Int = 2,
         oneway: Bool = false, crossingDistanceM: Double = 6.6) {
        self.featureId = id
        self.featureName = name
        self.level = level
        self.accessible = accessible
        self.coordinates = coordinates
        self.functionalClass = functionalClass
        self.lanes = lanes
        self.oneway = oneway
        self.crossingDistanceM = crossingDistanceM
        super.init()
    }

    func announcement() -> String { featureName }
    func getCoordinates() -> [CLLocationCoordinate2D] { coordinates }
}

// MARK: - Intersection

final class PortlandIntersection: NSObject, PortlandMapFeature, MKAnnotation, Identifiable {
    var id: String { featureId }

    let featureId: String
    let featureType: PortlandFeatureType = .intersection
    let featureName: String
    let level: Int
    let ways: Int
    let signalized: Bool
    let streets: [String]

    let coordinate: CLLocationCoordinate2D
    var title: String? { featureName }

    init(id: String, name: String, level: Int, coordinate: CLLocationCoordinate2D,
         ways: Int = 4, signalized: Bool = false, streets: [String] = []) {
        self.featureId = id
        self.featureName = name
        self.level = level
        self.coordinate = coordinate
        self.ways = ways
        self.signalized = signalized
        self.streets = streets
        super.init()
    }

    func announcement() -> String {
        let wayDesc = ways >= 3 ? "\(ways)-way" : "2-way"
        return "\(wayDesc) intersection, \(featureName)"
    }
}

/// Red square intersection marker (6 mm, white border) with an optional green
/// traffic-signal indicator dot in the corner (visual cue for low-vision users).
final class PortlandIntersectionAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "PortlandIntersection"
    private let signalDot = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        build()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    private func build() {
        backgroundColor = UIColor(red: 0xC1/255, green: 0x12/255, blue: 0x1F/255, alpha: 1)
        layer.borderColor = UIColor.white.cgColor
        signalDot.backgroundColor = .systemGreen
        signalDot.layer.borderColor = UIColor.white.cgColor
        signalDot.layer.borderWidth = 1
        signalDot.isHidden = true
        if signalDot.superview == nil { addSubview(signalDot) }
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        configure(side: PortlandPhysicalDimensions.mmToPoints(6.0))
    }

    /// Size the marker to the map (see `PortlandMapSizing`) with a tactile-minimum floor.
    func configure(side: CGFloat) {
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        layer.borderWidth = max(1, side * 0.08)
        let dot = max(7, side * 0.34)
        signalDot.frame = CGRect(x: side - dot/2, y: -dot/2, width: dot, height: dot)
        signalDot.layer.cornerRadius = dot/2
    }

    func showSignal(_ visible: Bool) { signalDot.isHidden = !visible }

    override func prepareForReuse() {
        super.prepareForReuse()
        signalDot.isHidden = true
    }
}

// MARK: - Landmark

final class PortlandLandmark: NSObject, PortlandMapFeature, MKAnnotation {
    let featureId: String
    let featureType: PortlandFeatureType = .landmark
    let featureName: String
    let level: Int
    let tag: String
    let side: String
    let announcementText: String
    let category: String

    let coordinate: CLLocationCoordinate2D
    var title: String? { featureName }

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

    func announcement() -> String { announcementText }
}

/// Purple landmark tag box (9×6 mm) showing the abbreviation.
final class PortlandLandmarkAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "PortlandLandmark"
    private let tagLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        build()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    private func build() {
        backgroundColor = UIColor(red: 0x7B/255, green: 0x2C/255, blue: 0xBF/255, alpha: 1)
        layer.borderColor = UIColor.white.cgColor
        configure(width: PortlandPhysicalDimensions.mmToPoints(9.0),
                  height: PortlandPhysicalDimensions.mmToPoints(6.0))

        if tagLabel.superview == nil {
            tagLabel.textColor = .white
            tagLabel.font = .systemFont(ofSize: 9, weight: .bold)
            tagLabel.textAlignment = .center
            tagLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tagLabel)
            NSLayoutConstraint.activate([
                tagLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                tagLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                tagLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2)
            ])
        }
    }

    func configure(width: CGFloat, height: CGFloat) {
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        layer.borderWidth = max(1, height * 0.08)
        layer.cornerRadius = height * 0.2
        tagLabel.font = .systemFont(ofSize: max(8, height * 0.42), weight: .bold)
    }

    override var annotation: MKAnnotation? {
        didSet {
            guard let lm = annotation as? PortlandLandmark else { return }
            tagLabel.text = lm.tag
            let dx = bounds.width * (lm.side == "left" ? -0.9 : 0.9)
            centerOffset = CGPoint(x: dx, y: 0)
        }
    }

    override func prepareForReuse() { super.prepareForReuse() }
}

// MARK: - Sidewalk / Crosswalk (Level-2 detail only)

final class PortlandSidewalk: NSObject, PortlandMapFeature {
    let featureId: String
    let featureType: PortlandFeatureType = .sidewalk
    let featureName: String
    let level: Int
    private let coordinates: [CLLocationCoordinate2D]

    lazy var polyline: MKPolyline = {
        var c = coordinates
        return MKPolyline(coordinates: &c, count: c.count)
    }()

    init(id: String, name: String, level: Int, coordinates: [CLLocationCoordinate2D]) {
        self.featureId = id; self.featureName = name; self.level = level
        self.coordinates = coordinates; super.init()
    }
    func announcement() -> String { featureName }
    func getCoordinates() -> [CLLocationCoordinate2D] { coordinates }
}

final class PortlandCrosswalk: NSObject, PortlandMapFeature {
    let featureId: String
    let featureType: PortlandFeatureType = .crosswalk
    let featureName: String
    let level: Int
    private let coordinates: [CLLocationCoordinate2D]   // walking-path centerline (hit-test)
    /// Zebra stripes (each a short bar parallel to traffic) generated by the loader; used
    /// for rendering only, so the visual matches a real marked crossing.
    let stripes: [[CLLocationCoordinate2D]]

    init(id: String, name: String, level: Int, coordinates: [CLLocationCoordinate2D],
         stripes: [[CLLocationCoordinate2D]] = []) {
        self.featureId = id; self.featureName = name; self.level = level
        self.coordinates = coordinates; self.stripes = stripes; super.init()
    }
    func announcement() -> String { featureName }
    func getCoordinates() -> [CLLocationCoordinate2D] { coordinates }
    func stripePolylines() -> [MKPolyline] {
        stripes.map { pts in var c = pts; return MKPolyline(coordinates: &c, count: c.count) }
    }
}

// MARK: - Time-of-day traffic state

/// The three time-of-day states the app exposes. Backed by FHWA urban hourly volume
/// profiles applied to HPMS-class AADT (see `portland_traffic.json`).
enum TrafficState: String, CaseIterable, Identifiable {
    case peak, normal, light

    var id: String { rawValue }
    var label: String {
        switch self {
        case .peak:   return "Peak"
        case .normal: return "Normal"
        case .light:  return "Light"
        }
    }
    var description: String {
        switch self {
        case .peak:   return "PM rush hour. Continuous traffic, few gaps to cross."
        case .normal: return "Midday. Moderate, steady traffic."
        case .light:  return "Late night. Sparse traffic with detectable gaps."
        }
    }
}

// MARK: - Traffic data models (match portland_traffic.json)

struct PortlandTrafficSegment: Codable {
    let id: String
    let corridorIds: [String]
    let name: String
    let functionalClass: String
    let lanes: Int
    let oneway: Bool
    let aadt: Int
    let speedLimitMph: Int
    let crossingDistanceM: Double
    let states: [String: StateVolume]

    struct StateVolume: Codable {
        let hour: Int
        let vph: Int
        let vphPerLane: Int
        let level: String

        enum CodingKeys: String, CodingKey {
            case hour, vph, level
            case vphPerLane = "vph_per_lane"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, lanes, oneway, aadt, states
        case corridorIds = "corridor_ids"
        case functionalClass = "functional_class"
        case speedLimitMph = "speed_limit_mph"
        case crossingDistanceM = "crossing_distance_m"
    }

    func level(for state: TrafficState) -> TrafficLevel {
        TrafficLevel(raw: states[state.rawValue]?.level ?? "moderate")
    }
    func vehiclesPerHour(for state: TrafficState) -> Int { states[state.rawValue]?.vph ?? 0 }
}

struct PortlandTrafficIntersection: Codable {
    let id: String
    let name: String
    let signalized: Bool
}

// MARK: - APS data models (mirror NYC Open Data APS schema)

struct PortlandAPS: Codable {
    let objectId: Int
    let intersectionId: String
    let onStreet: String
    let crossStreet: String
    let latitude: Double
    let longitude: Double
    let dateInstalled: String
    let manufacturer: String
    let device: Device
    let notes: String?

    struct Device: Codable {
        let locatorTone: Bool
        let locatorToneHz: Int
        let walkIndication: String       // "speech" | "percussive_tone"
        let walkMessage: String?
        let vibrotactileArrow: Bool
        let pushbutton: Bool
        let pushbuttonCorners: [String]
        let audibleBeaconing: Bool
        let countdownSeconds: Int

        enum CodingKeys: String, CodingKey {
            case locatorTone = "locator_tone"
            case locatorToneHz = "locator_tone_hz"
            case walkIndication = "walk_indication"
            case walkMessage = "walk_message"
            case vibrotactileArrow = "vibrotactile_arrow"
            case pushbutton
            case pushbuttonCorners = "pushbutton_corners"
            case audibleBeaconing = "audible_beaconing"
            case countdownSeconds = "countdown_seconds"
        }
    }

    enum CodingKeys: String, CodingKey {
        case objectId = "object_id"
        case intersectionId = "intersection_id"
        case onStreet = "on_street"
        case crossStreet = "cross_street"
        case latitude, longitude, manufacturer, device, notes
        case dateInstalled = "date_installed"
    }
}
