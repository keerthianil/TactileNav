//
//  TouchIndicatorView.swift
//  TactileNav
//
//  A small dot that follows the finger, on both tactile screens.
//
//  This is a sighted-observer aid and nothing else. The person using the app is exploring by
//  touch and cannot see it; it exists so a researcher watching over their shoulder — or a
//  recording of a session — can tell where the finger actually was when something was spoken.
//  That is the whole job, and it is why the view is never an accessibility element, never takes
//  a touch, and never feeds into what is announced.
//
//  It is deliberately smaller than every landmark the map draws (5 mm kerb dots, 6 mm route
//  ends and turns) and a colour none of them use, so an observer never mistakes the finger for
//  a thing on the map. Purple is the one hue left: blue is roadway, grey pavement, white paint,
//  red junctions, cyan the route, yellow its ends, orange its turns, pink the kerbs.
//

import TactileMapCore
import UIKit

final class TouchIndicatorView: UIView {

    /// Diameter in millimetres on the glass — the same physical-mm convention as everything
    /// else drawn on these screens, so the dot is the same size on every device.
    static let diameterMM: CGFloat = 4.0

    /// #9D4EDD. Light enough to read against the dark blue roadway and saturated enough to
    /// read against the white background, which a deeper purple manages only on one of them.
    static let color = UIColor(red: 0x9D / 255, green: 0x4E / 255, blue: 0xDD / 255, alpha: 1)

    private static var diameter: CGFloat { PhysicalDimensions.mmToPoints(diameterMM) }

    override init(frame: CGRect) {
        let size = Self.diameter
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(Self.color.cgColor)
        ctx.fillEllipse(in: rect)
    }

    /// Move the dot under the finger and show it.
    ///
    /// Inside a disabled `CATransaction`: without it the implicit position animation makes the
    /// dot lag the finger by a frame or two, which is exactly the error an observer is trying
    /// to read off the screen.
    func show(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        center = point
        isHidden = false
        CATransaction.commit()
    }

    func hide() { isHidden = true }
}
