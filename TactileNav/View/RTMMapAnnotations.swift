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

// (No location dot.) This map follows the Nav-Indoor / Indoor_Route design where the
// user's FINGER is the cursor: wherever the finger is, that point triggers feedback.
// While exploring, a transient ring + arrow (RTMTouchIndicatorView) is drawn right
// under the fingertip — see the bottom of this file.

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
    func applyGroundScale(pointsPerMeter: CGFloat, maxDiameter: CGFloat = 34) {
        let desired = min(max(groundDiameterMeters * pointsPerMeter, 8), maxDiameter)
        transform = CGAffineTransform(scaleX: desired / baseDiameter, y: desired / baseDiameter)
    }
}

// MARK: - Touch indicator (the finger cursor)

/// The "finger cursor," matching the old apps' touch indicator: a translucent yellow
/// ring with a white center dot and a white arrow that points the way the finger is
/// moving. It is NOT a map annotation — it's a plain overlay view positioned at the
/// finger's screen point. It only shows while the user is touching the map, and sits
/// exactly under the fingertip (no snapping), so what you feel matches where you touch.
final class RTMTouchIndicatorView: UIView {

    private let arrowLayer = CAShapeLayer()

    /// Square view; everything is drawn around its center, which we place at the finger.
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        isUserInteractionEnabled = false   // purely visual — never eats touches
        isHidden = true
        backgroundColor = .clear

        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // Translucent yellow ring + white outline.
        let ringRadius: CGFloat = 20
        let ringRect = CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                              width: ringRadius * 2, height: ringRadius * 2)
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: ringRect).cgPath
        ring.fillColor = UIColor(red: 1, green: 0.88, blue: 0, alpha: 0.28).cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 2.5
        layer.addSublayer(ring)

        // Small white center dot — marks the exact touch point.
        let dotRadius: CGFloat = 5
        let dotRect = CGRect(x: center.x - dotRadius, y: center.y - dotRadius,
                             width: dotRadius * 2, height: dotRadius * 2)
        let dot = CAShapeLayer()
        dot.path = UIBezierPath(ovalIn: dotRect).cgPath
        dot.fillColor = UIColor.white.cgColor
        layer.addSublayer(dot)

        // White arrow above the center, pointing "up" by default; we rotate the whole
        // view so it points the direction the finger is moving.
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: center.x, y: center.y - 36))        // tip
        arrow.addLine(to: CGPoint(x: center.x - 7, y: center.y - 22)) // base left
        arrow.addLine(to: CGPoint(x: center.x + 7, y: center.y - 22)) // base right
        arrow.close()
        arrowLayer.path = arrow.cgPath
        arrowLayer.fillColor = UIColor.white.cgColor
        layer.addSublayer(arrowLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Moves the indicator under the fingertip and (optionally) turns the arrow to the
    /// direction of travel. `heading` is in radians, 0 = up, clockwise positive.
    func move(to point: CGPoint, heading: CGFloat?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // follow the finger crisply, no lag
        center = point
        if let heading { transform = CGAffineTransform(rotationAngle: heading) }
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
