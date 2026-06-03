//
//  RTMMapAnnotations.swift
//  TactileNav  (RouxTactileMap)
//
//  THIS FILE IS
//  The "pins and dots" placed on the map, in two parts each: a small data object
//  (an annotation, which says WHERE and WHAT) and a view (which says how it LOOKS):
//   • Places (POIs)   -> red pins with a little icon (fork = restaurant, etc).
//   • Intersections   -> orange dots that grow/shrink as you zoom.
//   • Your location   -> a purple dot with an arrow showing which way you're going.
//  At the bottom, each POI category is matched to an SF Symbol for its pin icon.
//

import MapKit
import UIKit
import CoreLocation
import TactileMapCore   // PhysicalDimensions.mmToPoints — converts millimeters to screen points

// MARK: - Annotation models

/// A point-of-interest annotation. Its `coordinate` is the on-path anchor where the
/// marker is shown (the point you'd turn off from), which may differ from the POI's
/// real location.
final class RTMPOIAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let category: RTMPOICategory

    init(_ poi: RTMDiscoveredPOI, at coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        self.title = poi.name
        self.category = poi.category
    }
}

/// An intersection annotation (rendered as a small orange dot).
final class RTMIntersectionAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(_ intersection: RTMDiscoveredIntersection) {
        self.coordinate = intersection.coordinate
        self.title = intersection.name
    }
}

/// The draggable stand-in for the user's location. MKPointAnnotation's `coordinate`
/// is KVO-compliant, so reassigning it moves the view smoothly.
final class RTMSimulatedUserAnnotation: MKPointAnnotation {}

// MARK: - Annotation views

/// An orange intersection dot that scales with zoom (like the streets) so it stays
/// proportionate — small when zoomed out, larger when zoomed in.
final class RTMIntersectionAnnotationView: MKAnnotationView {
    private let baseDiameter = PhysicalDimensions.mmToPoints(8.0)
    private let groundDiameterMeters: CGFloat = 12

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: baseDiameter, height: baseDiameter)
        backgroundColor = .clear
        let dot = UIView(frame: bounds)
        dot.backgroundColor = .systemOrange
        dot.layer.cornerRadius = baseDiameter / 2
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 2
        dot.isUserInteractionEnabled = false
        dot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(dot)
        centerOffset = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Scales the dot to the current zoom, clamped so it stays tappable but never
    /// dominates the screen when zoomed out.
    func applyGroundScale(pointsPerMeter: CGFloat) {
        let desired = min(max(groundDiameterMeters * pointsPerMeter, 8), 34)
        transform = CGAffineTransform(scaleX: desired / baseDiameter, y: desired / baseDiameter)
    }
}

/// The simulated user location: a blue dot with a heading arrow above it. The view
/// rotates about its center (where the dot sits), so the arrow swings to point in
/// the direction of travel.
final class RTMSimulatedUserAnnotationView: MKAnnotationView {

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        let side: CGFloat = 48
        frame = CGRect(x: 0, y: 0, width: side, height: side)
        backgroundColor = .clear
        isUserInteractionEnabled = false   // dragging is handled by the map's pan recognizer
        centerOffset = .zero

        let center = CGPoint(x: side / 2, y: side / 2)
        let dotRadius: CGFloat = 11

        // Heading arrow: a triangle pointing up, sitting just above the dot.
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: center.x, y: center.y - dotRadius - 12))
        arrow.addLine(to: CGPoint(x: center.x - 7, y: center.y - dotRadius - 1))
        arrow.addLine(to: CGPoint(x: center.x + 7, y: center.y - dotRadius - 1))
        arrow.close()
        let arrowLayer = CAShapeLayer()
        arrowLayer.path = arrow.cgPath
        // Purple — distinct from blue roads, green paths, orange intersections, and
        // red POI markers, so the location dot stands out from every feature.
        arrowLayer.fillColor = UIColor.systemPurple.cgColor
        layer.addSublayer(arrowLayer)

        // The location dot: purple fill, white ring, soft shadow.
        let dotRect = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
        let dotLayer = CAShapeLayer()
        dotLayer.path = UIBezierPath(ovalIn: dotRect).cgPath
        dotLayer.fillColor = UIColor.systemPurple.cgColor
        dotLayer.strokeColor = UIColor.white.cgColor
        dotLayer.lineWidth = 3
        dotLayer.shadowColor = UIColor.black.cgColor
        dotLayer.shadowOpacity = 0.3
        dotLayer.shadowRadius = 3
        dotLayer.shadowOffset = .zero
        layer.addSublayer(dotLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rotates the arrow to face `heading` (radians, 0 = up, clockwise positive).
    func setHeading(_ heading: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transform = CGAffineTransform(rotationAngle: heading)
        CATransaction.commit()
    }
}

// MARK: - POI category → SF Symbol

extension RTMPOICategory {
    var symbolName: String {
        switch self {
        case .restaurant:   return "fork.knife"
        case .cafe:         return "cup.and.saucer.fill"
        case .hospital:     return "cross.fill"
        case .pharmacy:     return "pills.fill"
        case .school:       return "graduationcap.fill"
        case .university:   return "building.columns.fill"
        case .transit:      return "bus.fill"
        case .park:         return "tree.fill"
        case .store:        return "bag.fill"
        case .bank:         return "dollarsign.circle.fill"
        case .library:      return "books.vertical.fill"
        case .parking:      return "parkingsign"
        case .boatLaunch:   return "sailboat.fill"
        case .namedPlace:   return "mappin"
        case .userLocation: return "location.fill"
        case .other:        return "mappin"
        }
    }
}
