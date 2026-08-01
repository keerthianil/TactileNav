//
//  TactileNavTests.swift
//  TactileNavTests
//
//  Exercises the Congress Square map through its real pipeline: the bundled
//  OpenStreetMap extract, the projection into content points, and the hit testing a
//  finger relies on.
//

import CoreText
import SwiftUI
import TactileMapCore
import Testing
import UIKit
@testable import TactileNav

@MainActor
struct CongressSquareMapTests {

    private func loadMap() throws -> StreetMap {
        try PortlandMapLoader.loadStreetMap(context: PortlandMapLoader.LoadContext.current())
    }

    // MARK: - Data

    @Test func documentLoadsWithAllThreeSurfaces() throws {
        let map = try loadMap()

        let roads = map.features.filter { $0.surface == .road }
        let sidewalks = map.features.filter { $0.surface == .sidewalk }
        let crossings = map.features.filter { $0.surface == .crosswalk }

        // Real extract of downtown Portland: hundreds of each, not a handful of shapes.
        #expect(roads.count > 500)
        #expect(sidewalks.count > 400)
        #expect(crossings.count > 400)
        #expect(map.features.count == roads.count + sidewalks.count + crossings.count)
    }

    @Test func everyFeatureIsNamedAndDrawable() throws {
        let map = try loadMap()
        for feature in map.features {
            #expect(!feature.name.isEmpty, "\(feature.id) has no name")
            #expect(!feature.announcement.isEmpty, "\(feature.id) has nothing to say")
            #expect(feature.points.count >= 2, "\(feature.id) is not a line")
            #expect(feature.strokeWidth > 0)
            for point in feature.points {
                #expect(point.x.isFinite && point.y.isFinite)
            }
        }
    }

    @Test func geometryIsRealOpenStreetMapData() throws {
        let map = try loadMap()
        let names = Set(map.features.filter { $0.surface == .road }.map(\.name))

        // Streets that genuinely exist around Congress Square.
        for street in ["Congress Street", "High Street", "Free Street", "Oak Street",
                       "Park Street", "Spring Street", "State Street", "Commercial Street"] {
            #expect(names.contains(street), "missing \(street)")
        }
        // Curvature survives simplification rather than collapsing to straight lines.
        #expect(map.features.contains { $0.points.count >= 20 })
    }

    // MARK: - Physical sizing

    @Test func everyRoadIsDrawnOneLaneWideWhateverItsLaneCount() throws {
        let map = try loadMap()
        let lane = map.metrics.laneWidthPoints

        // 4 mm is the width a fingertip can follow, not a measurement of asphalt. Scaling it
        // by lane count would make a four-lane road 16 mm — wider than a fingertip, so no
        // longer a line you can trace, and wide enough to bury the sidewalk beside it.
        for feature in map.features where feature.surface == .road {
            #expect(abs(feature.strokeWidth - lane) < 0.01,
                    "\(feature.id) is \(feature.strokeWidth) pt, not one lane")
        }
        let widths = Set(map.features.filter { $0.surface == .road }.map(\.strokeWidth))
        #expect(widths.count == 1, "roads should all be the same width")

        // Lane count is still carried, for anything that wants it.
        #expect(map.features.contains { $0.surface == .road && $0.lanes >= 4 })
    }

    @Test func aFingerOnARoadFeelsTheRoad() throws {
        let map = try loadMap()
        var samples = 0, wrong = 0, silent = 0

        // Sample across the drawn width of every road — what a finger actually traces. A
        // sidewalk or crossing winning here means the user feels the soft sidewalk buzz, or a
        // tick, while looking at a road: the "it doesn't buzz" complaint.
        for road in map.features where road.surface == .road {
            let length = polylineLength(road.points)
            guard length > 4 else { continue }
            for step in stride(from: 0.0, through: length, by: max(length / 6, 20)) {
                guard let point = pointAlongPolyline(road.points, distance: step),
                      let next = pointAlongPolyline(road.points, distance: step + 1) else { continue }
                let delta = CGPoint(x: next.x - point.x, y: next.y - point.y)
                let magnitude = max(hypot(delta.x, delta.y), 0.001)
                let normal = CGPoint(x: -delta.y / magnitude, y: delta.x / magnitude)
                for across in stride(from: -0.45, through: 0.45, by: 0.15) {
                    let sample = CGPoint(x: point.x + normal.x * road.strokeWidth * across,
                                         y: point.y + normal.y * road.strokeWidth * across)
                    samples += 1
                    guard let hit = map.feature(at: sample, velocity: 0) else { silent += 1; continue }
                    if hit.surface != .road { wrong += 1 }
                }
            }
        }
        #expect(silent == 0, "\(silent) of \(samples) points on a road gave no feedback at all")

        // A few percent is expected and correct: at the very edge of a road beside a junction,
        // the painted crossing genuinely is the nearer line, and saying so is the right answer.
        // What this guards against is that number climbing back into double figures, which is
        // what it was when a crossing's catch radius outranked the road it sat on.
        let wrongShare = Double(wrong) / Double(samples)
        #expect(wrongShare < 0.03,
                "\(wrong) of \(samples) points on a road felt like something else")
    }

    @Test func mapScaleIsAnchoredToOneRealLane() throws {
        let map = try loadMap()
        // 4 mm on the glass is defined to be one 3.3 m traffic lane.
        let expected = map.metrics.laneWidthPoints / StreetMapSizing.laneWidthMeters
        #expect(abs(map.metrics.pointsPerMeter - expected) < 0.0001)

        // The whole extract is far larger than a screen, which is why the map must pan.
        #expect(map.contentSize.width > 8_000)
        #expect(map.contentSize.height > 5_000)
    }

    @Test func openingViewportComesFromTheDocument() throws {
        let map = try loadMap()
        // Congress Square, not the middle of the bounding box.
        let boxCenter = CGPoint(x: map.contentSize.width / 2, y: map.contentSize.height / 2)
        #expect(map.initialCenter != boxCenter)
        #expect((0...map.contentSize.width).contains(map.initialCenter.x))
        #expect((0...map.contentSize.height).contains(map.initialCenter.y))
        // It should land on the street grid, not in the harbour.
        #expect(map.nearestRoadName(to: map.initialCenter, within: 400) != nil)
    }

    // MARK: - Hit testing

    @Test func aPointOnAStreetFindsAStreet() throws {
        let map = try loadMap()
        let road = try #require(map.features.first { $0.surface == .road && $0.points.count >= 2 })
        let midpoint = polylineMidpoint(road.points)

        let hit = try #require(map.feature(at: midpoint, velocity: 0))
        // Whatever wins, the finger really is on it.
        #expect(distanceToPolyline(midpoint, hit.points) <= hit.hitRadius)
    }

    @Test func emptySpaceReturnsNothing() throws {
        let map = try loadMap()
        // Far outside the extract: no surface, so no haptic and nothing spoken.
        let outside = CGPoint(x: map.contentSize.width + 5_000, y: map.contentSize.height + 5_000)
        #expect(map.feature(at: outside, velocity: 0) == nil)
    }

    @Test func crossingsWinOverTheRoadTheySpan() throws {
        let map = try loadMap()
        // A crossing sits on top of a road, so it has to stay reachable — otherwise the
        // wider road underneath swallows it and a user can never find a crossing.
        let crossing = try #require(map.features.first { feature in
            guard feature.surface == .crosswalk else { return false }
            return map.nearestRoadName(to: polylineMidpoint(feature.points), within: 40) != nil
        })
        let hit = map.feature(at: polylineMidpoint(crossing.points), velocity: 0)
        #expect(hit?.surface == .crosswalk)
    }

    @Test func fasterDraggingWidensTheCatchRadius() throws {
        let map = try loadMap()
        let road = try #require(map.features.first { $0.surface == .road })
        let midpoint = polylineMidpoint(road.points)

        // A point just beyond the resting radius: a slow finger may miss it, a fast one
        // should not, because a fast drag samples further apart and would step over the line.
        let offset = CGPoint(x: midpoint.x, y: midpoint.y + road.hitRadius + 12)
        if map.feature(at: offset, velocity: 0) == nil {
            #expect(map.feature(at: offset, velocity: 2_000) != nil,
                    "a fast drag should still catch a line it steps over")
        }
    }

    // MARK: - Announcements

    @Test func spokenFormsFollowTheSurfaceConventions() throws {
        let map = try loadMap()

        // A road says its bare name; the surface is conveyed by the haptic instead.
        for road in map.features.filter({ $0.surface == .road }) {
            #expect(road.announcement == road.name)
        }
        // Sidewalks and crossings are ambiguous alone, so they name their street too.
        let sidewalks = map.features.filter { $0.surface == .sidewalk }
        #expect(sidewalks.contains { $0.announcement.contains(" sidewalk, ") })
        let crossings = map.features.filter { $0.surface == .crosswalk }
        #expect(crossings.contains { $0.announcement.hasPrefix("Crosswalk across ") })

        for sidewalk in sidewalks { #expect(sidewalk.announcement.contains("idewalk")) }
        for crossing in crossings { #expect(crossing.announcement.contains("rosswalk")) }
    }

    // MARK: - Rendering

    /// Renders the opening viewport and inspects the pixels.
    ///
    /// Asserting on colour rather than just "some bytes came out" is what actually proves the
    /// draw path works: that roads are stroked in road blue, sidewalks in sidewalk grey, and
    /// that the two are distinguishable — which is the whole point of giving them separate
    /// widths and textures.
    @Test func canvasRendersRoadsAndSidewalksInTheirOwnColours() throws {
        let map = try loadMap()
        let size = CGSize(width: 402, height: 720)

        let canvas = PortlandStreetCanvasView(frame: CGRect(origin: .zero, size: size))
        canvas.map = map
        canvas.contentOffset = CGPoint(x: map.initialCenter.x - size.width / 2,
                                       y: map.initialCenter.y - size.height / 2)

        // Call the draw method directly rather than rendering the layer: the layer has no
        // contents until the view is on screen, so rendering it would just yield white.
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            canvas.draw(canvas.bounds)
        }
        let tally = try Self.tally(of: image)
        let total = Int(size.width * size.height)

        // Classified by colour family rather than exact value: the render pipeline is colour
        // managed, so a stroke laid down as #023E8A does not come back as those exact bytes.
        #expect(tally.blue > total / 100, "almost no road was drawn (\(tally.blue) blue px)")
        #expect(tally.grey > total / 500, "almost no sidewalk was drawn (\(tally.grey) grey px)")
        // Both surfaces are present and distinguishable. Roads and sidewalks are drawn the
        // same width now, and most streets carry a sidewalk on each side, so grey legitimately
        // covers more area than blue — what matters is that neither has vanished.
        #expect(tally.blue > total / 200)
        // Background still shows through — this is a street map, not a solid block of ink.
        #expect(tally.white > total / 3)

        try #require(image.pngData()).write(
            to: Self.documentsDirectory.appendingPathComponent("congress_square_render.png"))

        // A wider window too, for checking street labels and the shape of the grid.
        let wide = CGSize(width: 1_200, height: 1_200)
        let wideCanvas = PortlandStreetCanvasView(frame: CGRect(origin: .zero, size: wide))
        wideCanvas.map = map
        wideCanvas.contentOffset = CGPoint(x: map.initialCenter.x - wide.width / 2,
                                          y: map.initialCenter.y - wide.height / 2)
        let wideImage = UIGraphicsImageRenderer(size: wide).image { _ in
            wideCanvas.draw(wideCanvas.bounds)
        }
        try #require(wideImage.pngData()).write(
            to: Self.documentsDirectory.appendingPathComponent("congress_square_wide.png"))

        // Labels must actually be placed somewhere on the map, not silently skipped.
        #expect(!map.labels.isEmpty)
    }

    // MARK: - Panning

    /// Builds the real view hierarchy and lays it out, which is the only way to catch the two
    /// things that silently break panning.
    /// The coordinator has to be held: the scroll view's delegate reference is weak, and
    /// SwiftUI is what normally keeps it alive.
    private struct LaidOutMap {
        let container: PortlandStreetMapContainerView
        let coordinator: PortlandMapView.Coordinator
        let map: StreetMap
    }

    private func laidOutContainer(size: CGSize) throws -> LaidOutMap {
        let map = try loadMap()
        let host = PortlandMapView(map: map)
        let coordinator = host.makeCoordinator()
        let container = host.makeContainer(coordinator: coordinator)
        container.frame = CGRect(origin: .zero, size: size)
        container.layoutIfNeeded()
        return LaidOutMap(container: container, coordinator: coordinator, map: map)
    }

    @Test func touchesReachTheScrollViewSoThePanCanStart() throws {
        let size = CGSize(width: 402, height: 720)
        let container = try laidOutContainer(size: size).container

        // The content spacer must never take a touch. If it does, the scroll view treats the
        // touch as content and will not steal it back to begin a pan — the map just refuses
        // to move in any direction.
        #expect(container.spacer.isUserInteractionEnabled == false)

        let hit = container.hitTest(CGPoint(x: size.width / 2, y: size.height / 2), with: nil)
        #expect(hit === container.scrollView, "touches must land on the scroll view itself")
    }

    @Test func scrollViewIsConfiguredForTwoFingerPanningOnly() throws {
        let container = try laidOutContainer(size: CGSize(width: 402, height: 720)).container
        let pan = container.scrollView.panGestureRecognizer

        // One finger is the exploration channel, so it must never pan.
        #expect(pan.minimumNumberOfTouches == 2)
        // Three fingers is the back gesture, so it must never also pan.
        #expect(pan.maximumNumberOfTouches == 2)
        // Physical millimetre sizing is only true at one scale.
        #expect(container.scrollView.minimumZoomScale == 1)
        #expect(container.scrollView.maximumZoomScale == 1)
    }

    @Test func theMapCanActuallyScrollInBothDirections() throws {
        let size = CGSize(width: 402, height: 720)
        let container = try laidOutContainer(size: size).container
        let scrollView = container.scrollView

        // Content has to be bigger than the viewport in both axes or there is nothing to pan.
        #expect(scrollView.contentSize.width > size.width)
        #expect(scrollView.contentSize.height > size.height)

        let start = scrollView.contentOffset
        scrollView.contentOffset = CGPoint(x: start.x + 300, y: start.y + 300)
        container.layoutIfNeeded()
        #expect(scrollView.contentOffset.x == start.x + 300)
        #expect(scrollView.contentOffset.y == start.y + 300)
        // The canvas has to follow, or panning moves nothing visible.
        #expect(container.canvas.contentOffset == scrollView.contentOffset)
    }

    @Test func theViewportOpensOnCongressSquareNotTheCorner() throws {
        let size = CGSize(width: 402, height: 720)
        let laidOut = try laidOutContainer(size: size)
        let container = laidOut.container
        let map = laidOut.map

        // Centring runs off first layout. If it waited for a SwiftUI update pass it would
        // never happen, and the map would open in the corner of the extract.
        let center = CGPoint(x: container.scrollView.contentOffset.x + size.width / 2,
                             y: container.scrollView.contentOffset.y + size.height / 2)
        #expect(abs(center.x - map.initialCenter.x) < 2)
        #expect(abs(center.y - map.initialCenter.y) < 2)
        #expect(container.scrollView.contentOffset != .zero)
    }

    // MARK: - Back navigation

    @Test func onlyThreeFingerSwipeAndTheBackButtonNavigateAway() throws {
        let container = try laidOutContainer(size: CGSize(width: 402, height: 720)).container
        let scrollView = container.scrollView

        var backCount = 0
        scrollView.onBackGesture = { backCount += 1 }

        // Two-finger scrub must not escape — nothing but three fingers and the Back button
        // may leave the screen.
        #expect(scrollView.accessibilityPerformEscape() == false)
        #expect(backCount == 0)

        #expect(scrollView.accessibilityScroll(.right) == true)
        #expect(backCount == 1)
        #expect(scrollView.accessibilityScroll(.left) == false)
        #expect(backCount == 1)
    }

    /// The one-finger swipe-back has to be dead while the map is open.
    ///
    /// Clearing `isEnabled` alone does not hold — SwiftUI re-enables the recognizer as the
    /// navigation stack updates — so the delegate is taken over as well. This builds a real
    /// navigation controller because that is the only way to find out whether the responder
    /// walk actually reaches one.
    @Test func oneFingerSwipeCannotLeaveTheMap() throws {
        let map = try loadMap()
        let host = PortlandMapView(map: map)
        let coordinator = host.makeCoordinator()
        let container = host.makeContainer(coordinator: coordinator)

        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        navigation.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)

        let pushed = UIViewController()
        navigation.pushViewController(pushed, animated: false)
        pushed.view.addSubview(container)
        container.frame = pushed.view.bounds
        navigation.view.layoutIfNeeded()
        container.layoutIfNeeded()

        let pop = try #require(navigation.interactivePopGestureRecognizer)
        #expect(pop.isEnabled == false, "the swipe-back is still enabled over the map")
        #expect(pop.delegate is SwipeBackBlocker, "the swipe-back delegate was not taken over")
        #expect(pop.delegate?.gestureRecognizerShouldBegin?(pop) == false)

        // Even if something re-enables it — which SwiftUI does — the delegate still refuses to
        // let it start, and the next layout clears the flag again.
        pop.isEnabled = true
        #expect(pop.delegate?.gestureRecognizerShouldBegin?(pop) == false,
                "the delegate must keep refusing even while enabled")
        container.setNeedsLayout()
        container.layoutIfNeeded()
        #expect(pop.isEnabled == false, "re-enabling should be undone on the next layout")

        // And the rest of the app gets its swipe back when the map goes away.
        container.restoreSwipeBack()
        #expect(pop.isEnabled == true)
        #expect(!(pop.delegate is SwipeBackBlocker))
    }

    // MARK: - Exploration touches

    /// Exploration must not depend on a gesture recognizer.
    ///
    /// Inside a direct-interaction accessibility element VoiceOver hands touches to the
    /// responder chain, and recognizers on that view do not fire dependably — which is how the
    /// map ended up buzzing with VoiceOver off and doing nothing at all with it on.
    @Test func explorationRunsOnRawTouchesNotGestureRecognizers() throws {
        let laidOut = try laidOutContainer(size: CGSize(width: 402, height: 720))
        let scrollView = laidOut.container.scrollView

        // None of the recognizers we add may be a tap or long-press: those are the ones that
        // go silent under VoiceOver. UIScrollView's own scrollbar-knob recognizers are long
        // presses too, so only the ones this screen owns are checked.
        let ours = (scrollView.gestureRecognizers ?? []).filter {
            $0.delegate === laidOut.coordinator
        }
        #expect(!ours.isEmpty, "the back gestures should still be recognizers")
        for recognizer in ours {
            #expect(!(recognizer is UITapGestureRecognizer),
                    "exploration must not rely on a tap recognizer")
            #expect(!(recognizer is UILongPressGestureRecognizer),
                    "exploration must not rely on a long-press recognizer")
        }

        // The raw touch callbacks are wired.
        #expect(scrollView.onExploreBegan != nil)
        #expect(scrollView.onExploreMoved != nil)
        #expect(scrollView.onExploreEnded != nil)
        #expect(scrollView.onExploreTapped != nil)
    }

    @Test func aTouchOnAStreetStartsTheRightFeedback() throws {
        let laidOut = try laidOutContainer(size: CGSize(width: 402, height: 720))
        let map = laidOut.map

        // Drive the same lookup the touch handler uses, on a point that is genuinely on a
        // street. (The opening centre is a junction, which need not sit exactly on a line.)
        let road = try #require(map.features.first { $0.surface == .road })
        let feature = try #require(map.feature(at: polylineMidpoint(road.points), velocity: 0))
        let element = StreetSurfaceElement(id: feature.id, surface: feature.surface,
                                           announcement: feature.announcement)

        // Each surface maps to its own element type, which is what selects the haptic.
        switch feature.surface {
        case .road: #expect(element.elementType == .road)
        case .sidewalk: #expect(element.elementType == .street)
        case .crosswalk: #expect(element.elementType == .crosswalk)
        }
        #expect(element.properties.name == feature.announcement)
    }

    // MARK: - Pixel helpers


    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private struct PixelTally {
        var white = 0
        var blue = 0
        var grey = 0
        var other = 0
    }

    private static func tally(of image: UIImage) throws -> PixelTally {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let context = try #require(CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var tally = PixelTally()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            if r > 240, g > 240, b > 240 {
                tally.white += 1
            } else if b > r + 40, b > g + 20 {
                tally.blue += 1                                  // road
            } else if abs(r - g) < 14, abs(g - b) < 14, (110...190).contains(r) {
                tally.grey += 1                                  // sidewalk
            } else {
                tally.other += 1
            }
        }
        return tally
    }
}

// MARK: - Street Crossing Audio

/// The crossing demo only teaches anything if the geometry genuinely separates parallel
/// traffic from cross traffic. If both sounded the same there would be nothing to learn.
@MainActor
struct IntersectionCrossingTests {

    private let legLength = IntersectionCrossingModel.legLengthM

    private func vehicle(_ entry: IntersectionLeg, _ exit: IntersectionLeg,
                         age: TimeInterval) -> SimulatedVehicle {
        var vehicle = SimulatedVehicle(type: .car, entryLeg: entry, exitLeg: exit, speedMps: 10)
        vehicle.age = age
        return vehicle
    }

    /// Seconds for a vehicle at 10 m/s to reach the middle of its run, i.e. the intersection.
    private var timeAtCentre: TimeInterval { legLength / 10 }

    // MARK: Geometry

    /// How far the stereo image swings over a whole pass — the thing an ear actually keys on.
    private func panSwing(_ entry: IntersectionLeg, _ exit: IntersectionLeg) -> Double {
        var lowest = Double.greatestFiniteMagnitude
        var highest = -Double.greatestFiniteMagnitude
        for step in stride(from: 0.0, through: timeAtCentre * 2, by: timeAtCentre / 40) {
            let position = vehicle(entry, exit, age: step).position(legLength: legLength)
            let distance = max(0.8, hypot(Double(position.x), Double(position.y)))
            let pan = max(-1, min(1, Double(position.x) / distance))
            lowest = min(lowest, pan)
            highest = max(highest, pan)
        }
        return highest - lowest
    }

    @Test func crossTrafficSweepsAcrossTheStereoImage() {
        // Congress Street is the street being crossed, so its traffic should travel right
        // across the front — a pan that swings nearly ear to ear. That sweep is the cue that
        // means wait.
        let swing = panSwing(.congressWest, .congressEast)
        #expect(swing > 1.2, "cross traffic barely moved across the stereo image: \(swing)")
    }

    @Test func parallelTrafficStaysAheadAndBehindInsteadOfSweeping() {
        // High Street runs along the listener's path, so its traffic passes close to straight
        // ahead and back. If it swung across like cross traffic, the two would be
        // indistinguishable by ear and the exercise would have no answer.
        let parallel = panSwing(.highSouth, .highNorth)
        let crossing = panSwing(.congressWest, .congressEast)
        #expect(parallel < crossing / 2,
                "parallel swing \(parallel) is not clearly smaller than cross swing \(crossing)")
    }

    @Test func crossTrafficActuallyChangesSides() {
        // It has to travel from one side to the other, or there is no left-to-right sweep to
        // hear and the pan never moves.
        let early = vehicle(.congressWest, .congressEast, age: timeAtCentre * 0.35)
            .position(legLength: legLength)
        let late = vehicle(.congressWest, .congressEast, age: timeAtCentre * 1.65)
            .position(legLength: legLength)
        #expect(early.x * late.x < 0, "should cross from one side to the other: \(early) → \(late)")
    }

    /// Seconds a movement spends within `radius` of the listener.
    private func dwell(_ entry: IntersectionLeg, _ exit: IntersectionLeg, within radius: Double) -> Double {
        let samples = 400
        let duration = timeAtCentre * 2
        var inside = 0
        for step in 0..<samples {
            let age = duration * Double(step) / Double(samples - 1)
            let position = vehicle(entry, exit, age: age).position(legLength: legLength)
            if hypot(Double(position.x), Double(position.y)) < radius { inside += 1 }
        }
        return duration * Double(inside) / Double(samples)
    }

    @Test func aTurningVehicleLingersInsteadOfPassing() {
        // The hazard is that a turning car hangs around near the crossing rather than sweeping
        // past and away. Compared with a through movement off the *same* leg, the turn should
        // stay close for noticeably longer — that lingering is the cue the screen tells people
        // to listen for.
        let turning = dwell(.highSouth, .congressWest, within: 15)
        let through = dwell(.highSouth, .highNorth, within: 15)
        #expect(vehicle(.highSouth, .congressWest, age: 0).isTurning)
        #expect(!vehicle(.highSouth, .highNorth, age: 0).isTurning)
        #expect(turning > through * 1.3,
                "turn lingered \(turning)s vs through \(through)s — not a distinguishable cue")
    }

    @Test func nearLaneTrafficIsClearlyCloserThanFarLane() {
        // Vehicles keep right, so one direction of Congress Street passes right in front of
        // the listener and the other is a full roadway away. If both ran down the centreline
        // they would sound identical and the intersection would carry no information.
        func closest(_ entry: IntersectionLeg, _ exit: IntersectionLeg) -> Double {
            stride(from: 0.0, through: timeAtCentre * 2, by: timeAtCentre / 60).map {
                let position = vehicle(entry, exit, age: $0).position(legLength: legLength)
                return hypot(Double(position.x), Double(position.y))
            }.min() ?? .greatestFiniteMagnitude
        }
        let near = closest(.congressWest, .congressEast)
        let far = closest(.congressEast, .congressWest)
        #expect(near < far / 1.8, "near lane \(near) m vs far lane \(far) m is not a real difference")
        #expect(near < 8, "the near lane should pass close enough to be unmistakable")
    }

    @Test func vehiclesApproachThenRecede() {
        // Distance must fall then rise, or there is no Doppler curve to hear.
        let distances = stride(from: 0.0, through: timeAtCentre * 2, by: timeAtCentre / 8).map {
            let position = vehicle(.congressWest, .congressEast, age: $0).position(legLength: legLength)
            return hypot(Double(position.x), Double(position.y))
        }
        let closest = try! #require(distances.min())
        #expect(distances.first! > closest)
        #expect(distances.last! > closest)
        #expect(closest < 20, "traffic should pass close enough to be clearly audible")
    }

    // MARK: Signal cycle

    @Test func theCycleAlternatesGreensWithAllRedBetween() {
        #expect(SignalPhase.cycleLength == 44)

        // Walk is only ever during the parallel green.
        let walk = SignalPhase.phase(at: 5).phase
        #expect(walk.isWalkPhase)
        #expect(walk.kind == .green(.high))

        #expect(SignalPhase.phase(at: 20).phase.kind == .allRed)
        #expect(SignalPhase.phase(at: 30).phase.kind == .green(.congress))
        #expect(SignalPhase.phase(at: 30).phase.isWalkPhase == false)

        // And it repeats.
        #expect(SignalPhase.phase(at: 5 + SignalPhase.cycleLength).phase.kind == walk.kind)
    }

    // MARK: Traffic generation

    @Test func trafficFlowsOnAllFourLegsOverTime() {
        let model = IntersectionCrossingModel()
        var seen = Set<IntersectionLeg>()
        for _ in 0..<3_000 {
            _ = model.advance(by: 1.0 / 30.0)
            for vehicle in model.vehicles { seen.insert(vehicle.entryLeg) }
        }
        #expect(seen.count == 4, "expected traffic on every leg, saw \(seen.map(\.rawValue))")
    }

    @Test func vehiclesOnlyMoveOnTheirOwnGreen() {
        let model = IntersectionCrossingModel()
        for _ in 0..<2_000 {
            _ = model.advance(by: 1.0 / 30.0)
            guard case .green(let movement) = model.currentPhase.kind else { continue }
            for vehicle in model.vehicles {
                // A vehicle spawned on the previous green may still be clearing, so only
                // check the ones that have just entered.
                guard vehicle.age < 0.5 else { continue }
                #expect(vehicle.entryLeg.phase == movement,
                        "\(vehicle.entryLeg.rawValue) entered during the wrong phase")
            }
        }
    }

    @Test func turnsAcrossTheCrosswalkOnlyHappenDuringTheWalkPhase() {
        let model = IntersectionCrossingModel()
        var sawTurn = false
        for _ in 0..<4_000 {
            _ = model.advance(by: 1.0 / 30.0)
            for vehicle in model.vehicles where vehicle.isTurning && vehicle.age < 0.5 {
                sawTurn = true
                #expect(vehicle.entryLeg.phase == .high)
            }
        }
        #expect(sawTurn, "the turning hazard never appeared")
    }

    @Test func trafficNeverExceedsTheAvailableVoices() {
        let model = IntersectionCrossingModel()
        for _ in 0..<4_000 {
            _ = model.advance(by: 1.0 / 30.0)
            #expect(model.vehicles.count <= TrafficAudioEngine.voiceCount)
        }
    }

    @Test func anElectricFleetIsEntirelyElectric() {
        let model = IntersectionCrossingModel()
        model.fleet = .electric
        var count = 0
        for _ in 0..<2_000 {
            _ = model.advance(by: 1.0 / 30.0)
            for vehicle in model.vehicles {
                #expect(vehicle.type.isEV)
                count += 1
            }
        }
        #expect(count > 0)
        // And it is genuinely much quieter, which is the whole point of the comparison.
        #expect(TrafficAudioEngine.VehicleType.ev.loudness
                < TrafficAudioEngine.VehicleType.car.loudness / 2)
    }

    @Test func departedVehiclesAreHandedBackSoTheirVoicesCanBeFreed() {
        let model = IntersectionCrossingModel()
        var departed = 0
        for _ in 0..<4_000 {
            departed += model.advance(by: 1.0 / 30.0).count
        }
        #expect(departed > 0, "vehicles must be reported when they leave, or voices leak")
    }
}

// MARK: - Visual check

@MainActor
struct CrossingDemoRenderTests {

    /// Renders the diagram mid-cycle so it can be eyeballed after a test run.
    @Test func intersectionDiagramRenders() throws {
        let model = IntersectionCrossingModel()
        // Run into a green so there is traffic on the road to draw.
        for _ in 0..<300 { _ = model.advance(by: 1.0 / 30.0) }
        #expect(!model.vehicles.isEmpty)

        let renderer = ImageRenderer(content:
            IntersectionDiagramView(vehicles: model.vehicles).frame(width: 360, height: 260)
        )
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        let data = try #require(image.pngData())
        #expect(data.count > 5_000)
        try data.write(to: FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("crossing_demo.png"))
    }
}
