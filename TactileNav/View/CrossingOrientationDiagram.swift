//
//  CrossingOrientationDiagram.swift
//  TactileNav
//
//  A picture of where you are standing at the crossing-audio junction.
//
//  Drawn from the same numbers the audio is computed from — the real OpenStreetMap bearings of
//  Congress Street and High Street, and the listener position `DemoIntersection` places on the
//  corner. So the figure is standing exactly where the sound is being heard from, and cannot
//  drift out of step with it.
//
//  Sighted aid only. It is never an accessibility element in its own right; the orientation it
//  shows is given to VoiceOver as a sentence by the screen that owns it.
//

import SwiftUI

struct CrossingOrientationDiagram: View {

    /// Live vehicles, in listener-relative metres. Empty when the simulation is stopped.
    var vehicles: [SimulatedVehicle] = []

    /// How much ground the diagram covers, measured from the junction centre. Wide enough
    /// that the junction reads as a junction with streets leading away from it, rather than
    /// as two bands filling the frame.
    private let radiusMeters: CGFloat = 58

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = (side / 2) / radiusMeters

            /// World metres (+x east, +y north) → a point in this north-up drawing.
            func place(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: centre.x + CGFloat(x) * scale, y: centre.y - CGFloat(y) * scale)
            }

            drawRoadways(in: context, centre: centre, scale: scale, side: side, place: place)
            drawCrossing(in: context, scale: scale, place: place)
            drawVehicles(in: context, scale: scale, place: place)
            drawListener(in: context, scale: scale, place: place)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.separator)))
        // The screen states the orientation in words for VoiceOver; this is the picture of it.
        .accessibilityHidden(true)
    }

    // MARK: - Pieces

    private func drawRoadways(in context: GraphicsContext, centre: CGPoint, scale: CGFloat,
                              side: CGFloat, place: (Double, Double) -> CGPoint) {
        let width = CGFloat(DemoIntersection.roadHalfWidthM * 2) * scale
        // Long enough to run off the drawing in both directions.
        let reach = Double(side / scale)

        for bearing in [DemoIntersection.congressBearings.outbound,
                        DemoIntersection.highBearings.outbound] {
            let along = DemoIntersection.direction(bearing)
            var path = Path()
            path.move(to: place(-along.x * reach, -along.y * reach))
            path.addLine(to: place(along.x * reach, along.y * reach))
            context.stroke(path, with: .color(Color(cgColor: IntersectionPalette.road)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    /// The crossing the listener is about to use: straight ahead of them, over Congress Street.
    ///
    /// You walk along High Street to cross Congress, so the crossing runs along High and its
    /// span is the width of the Congress roadway. The bars are laid *across* the direction you
    /// walk — that is what a zebra is — which means each bar lies along Congress.
    private func drawCrossing(in context: GraphicsContext, scale: CGFloat,
                              place: (Double, Double) -> CGPoint) {
        let centre = DemoIntersection.crosswalkCenterM
        let walk = DemoIntersection.direction(DemoIntersection.highBearings.outbound)
        let bar = DemoIntersection.direction(DemoIntersection.congressBearings.outbound)
        let half = DemoIntersection.roadHalfWidthM
        let barHalfLength = 2.8

        // Step along the walking direction, spanning the roadway being crossed.
        for step in stride(from: -half + 1.0, through: half - 1.0, by: 2.4) {
            let base = CGPoint(x: Double(centre.x) + walk.x * step,
                               y: Double(centre.y) + walk.y * step)
            var stripe = Path()
            stripe.move(to: place(base.x - bar.x * barHalfLength, base.y - bar.y * barHalfLength))
            stripe.addLine(to: place(base.x + bar.x * barHalfLength, base.y + bar.y * barHalfLength))
            context.stroke(stripe, with: .color(.white),
                           style: StrokeStyle(lineWidth: max(scale * 0.9, 3), lineCap: .butt))
        }
    }

    private func drawVehicles(in context: GraphicsContext, scale: CGFloat,
                              place: (Double, Double) -> CGPoint) {
        guard !vehicles.isEmpty else { return }
        let listener = DemoIntersection.listenerPositionM
        let facing = DemoIntersection.listenerFacing * .pi / 180

        for vehicle in vehicles {
            // Vehicle positions are listener-relative and listener-facing; undo both so the
            // drawing stays north-up while the audio stays in the listener's frame.
            let relative = vehicle.position(legLength: IntersectionCrossingModel.legLengthM)
            let dx = Double(relative.x) * cos(facing) + Double(relative.y) * sin(facing)
            let dy = -Double(relative.x) * sin(facing) + Double(relative.y) * cos(facing)
            let point = place(Double(listener.x) + dx, Double(listener.y) + dy)

            let radius = max(scale * 1.1, 3)
            let box = CGRect(x: point.x - radius, y: point.y - radius,
                             width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: box),
                         with: .color(vehicle.type.isEV ? .green : .orange))
        }
    }

    /// The listener: a dot on the corner with a wedge showing which way they face.
    private func drawListener(in context: GraphicsContext, scale: CGFloat,
                              place: (Double, Double) -> CGPoint) {
        let stand = DemoIntersection.listenerPositionM
        let at = place(Double(stand.x), Double(stand.y))
        let forward = DemoIntersection.direction(DemoIntersection.listenerFacing)

        // A wedge rather than an arrow: it reads as a field of view, which is what facing
        // means here — the direction the ears are pointed and the way the walk goes.
        let reach = max(scale * 7, 22)
        let spread = 0.42
        let heading = atan2(forward.x, forward.y)
        var wedge = Path()
        wedge.move(to: at)
        wedge.addLine(to: CGPoint(x: at.x + sin(heading - spread) * reach,
                                  y: at.y - cos(heading - spread) * reach))
        wedge.addLine(to: CGPoint(x: at.x + sin(heading + spread) * reach,
                                  y: at.y - cos(heading + spread) * reach))
        wedge.closeSubpath()
        context.fill(wedge, with: .color(.accentColor.opacity(0.30)))

        // A white disc so the figure reads against the roadway it stands beside, with the
        // figure itself drawn on top of it.
        let radius = max(scale * 1.9, 11)
        let body = CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: body), with: .color(.white))
        context.stroke(Path(ellipseIn: body), with: .color(.accentColor), lineWidth: 2.5)
        context.draw(
            Text(Image(systemName: "figure.stand"))
                .font(.system(size: radius * 1.5, weight: .bold))
                .foregroundColor(.accentColor),
            at: at)
    }
}
