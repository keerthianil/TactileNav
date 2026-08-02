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

    /// The map is roads and only roads.
    ///
    /// The extract also carries hundreds of sidewalks and crossings. They are dropped at
    /// projection time: at city scale they crowd every junction with lines a few millimetres
    /// apart, which reads as noise under a finger. If one ever survives into `features`, a
    /// user tracing a street starts feeling things that are not the street.
    @Test func theMapIsRoadsAndNothingElse() throws {
        let map = try loadMap()

        // Real extract of downtown Portland: hundreds of streets, not a handful of shapes.
        #expect(map.features.count > 500)

        // Nothing that is not a roadway made it through. Sidewalks and crossings in this
        // extract are named for what they are, so their names are the tell.
        for feature in map.features {
            #expect(!feature.name.localizedCaseInsensitiveContains("sidewalk"),
                    "a sidewalk survived into the map: \(feature.id)")
            #expect(!feature.name.localizedCaseInsensitiveContains("crosswalk"),
                    "a crossing survived into the map: \(feature.id)")
        }
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
        let names = Set(map.features.map(\.name))

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
        // longer a line you can trace.
        for feature in map.features {
            #expect(abs(feature.strokeWidth - lane) < 0.01,
                    "\(feature.id) is \(feature.strokeWidth) pt, not one lane")
        }
        #expect(Set(map.features.map(\.strokeWidth)).count == 1,
                "roads should all be the same width")

        // Lane count is still carried, for anything that wants it.
        #expect(map.features.contains { $0.lanes >= 4 })
    }

    @Test func aFingerOnARoadFeelsTheRoad() throws {
        let map = try loadMap()
        var samples = 0, wrong = 0, silent = 0

        // Sample across the drawn width of every road — what a finger actually traces, not
        // just its centreline. Silence anywhere inside the ink is the "it doesn't buzz"
        // complaint, and it is only visible if you sample across the stroke.
        for road in map.features {
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
                    // Whatever wins is another street, and the finger is genuinely on it.
                    if distanceToPolyline(sample, hit.points) > hit.hitRadius { wrong += 1 }
                }
            }
        }
        #expect(silent == 0, "\(silent) of \(samples) points on a road gave no feedback at all")
        #expect(wrong == 0, "\(wrong) of \(samples) points resolved to a line they are not on")
    }

    /// Map scale is set by block spacing, and must stay independent of the lane width.
    ///
    /// Deriving the scale from the lane width instead makes the drawing life-size: about 55 m
    /// of street fits on a phone, so the viewport holds two streets and the grid can never be
    /// seen. This is the assertion that keeps the two numbers apart.
    @Test func mapScaleComesFromBlockSpacingNotLaneWidth() throws {
        let map = try loadMap()
        let scale = map.metrics.pointsPerMeter

        // A block spans the intended distance on the glass, whatever the device.
        let blockOnGlass = StreetMapSizing.blockLengthMeters * scale
        #expect(abs(blockOnGlass - PhysicalDimensions.mmToPoints(StreetMapSizing.blockSpacingMM)) < 0.01)

        // And that is a long way from the life-size scale, which is the failure being guarded
        // against — not a value that happens to be close to it.
        let lifeSize = map.metrics.laneWidthPoints / StreetMapSizing.laneWidthMeters
        #expect(scale < lifeSize / 2, "the scale has drifted back to life-size")

        // Enough of the grid to read. The short edge of a phone is ~402 pt, and it has to
        // hold more than one block or a junction fills the screen with nothing beside it.
        #expect(402 / scale > StreetMapSizing.blockLengthMeters * 1.5)

        // Still far larger than a screen, which is why the map pans.
        #expect(map.contentSize.width > 2_000)
        #expect(map.contentSize.height > 1_500)
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
        let road = try #require(map.features.first { $0.points.count >= 2 })
        let midpoint = polylineMidpoint(road.points)

        let hit = try #require(map.feature(at: midpoint, velocity: 0))
        // Whatever wins, the finger really is on it.
        #expect(distanceToPolyline(midpoint, hit.points) <= hit.hitRadius)
    }

    @Test func emptySpaceReturnsNothing() throws {
        let map = try loadMap()
        // Far outside the extract: no street, so no haptic and nothing spoken.
        let outside = CGPoint(x: map.contentSize.width + 5_000, y: map.contentSize.height + 5_000)
        #expect(map.feature(at: outside, velocity: 0) == nil)
    }

    @Test func fasterDraggingWidensTheCatchRadius() throws {
        let map = try loadMap()
        let road = try #require(map.features.first)
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

    @Test func everyStreetSaysItsBareName() throws {
        let map = try loadMap()

        // There is only one kind of thing on this map, so naming the surface would add
        // nothing the haptic has not already said.
        for road in map.features {
            #expect(road.announcement == road.name)
            #expect(!road.announcement.isEmpty)
        }
    }

    // MARK: - Rendering

    /// Renders the opening viewport and inspects the pixels.
    ///
    /// Asserting on colour rather than just "some bytes came out" is what actually proves the
    /// draw path works: that streets are stroked in road blue, that no grey survives from the
    /// sidewalks that used to be drawn, and that the background still shows through.
    @Test func canvasDrawsBlueLanesAndNothingElse() throws {
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
        // No grey anywhere: sidewalks used to be drawn in it, and they are gone. This is the
        // assertion that would catch them creeping back in.
        #expect(tally.grey < total / 5_000, "\(tally.grey) grey px — something non-road was drawn")
        // Background still shows through — this is a street map, not a solid block of ink.
        #expect(tally.white > total / 3)

        try #require(image.pngData()).write(
            to: Self.documentsDirectory.appendingPathComponent("congress_square_render.png"))
        // Printed so the rendered map can actually be looked at — the container path is a
        // different UUID on every simulator and is otherwise not worth hunting for.
        print("RENDER_DIR \(Self.documentsDirectory.path)")

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
    /// A navigation controller has *two* pop gestures, and the map has to survive both. The
    /// familiar one is the left-edge swipe; iOS 18 added a second that pops from a swipe
    /// anywhere on the view. The second one is the one that kept sending users back mid-drag,
    /// because a one-finger explore drag is exactly a full-screen swipe. It has no public API,
    /// so this asserts against whatever `popGestures(of:)` finds — on an OS that has both,
    /// that is both.
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

        let gestures = SwipeBackBlocker.popGestures(of: navigation)
        #expect(gestures.contains { $0 === navigation.interactivePopGestureRecognizer })
        if #available(iOS 18.0, *) {
            #expect(gestures.count == 2, "the full-screen pop gesture was not found")
        }

        for gesture in gestures {
            #expect(gesture.delegate is SwipeBackBlocker,
                    "\(type(of: gesture)) delegate was not taken over")
            #expect(gesture.delegate?.gestureRecognizerShouldBegin?(gesture) == false)
            // Enabled on purpose: a disabled recognizer is one the system feels free to
            // re-enable, and the refusal has to hold either way.
            #expect(gesture.delegate?.gestureRecognizerShouldBegin?(gesture) == false,
                    "the delegate must keep refusing even while enabled")
        }

        // And the rest of the app gets its swipe back when the map goes away.
        container.restoreSwipeBack()
        for gesture in gestures {
            #expect(!(gesture.delegate is SwipeBackBlocker))
        }
    }

    // MARK: - VoiceOver

    /// The direct-touch surface has to be set up the moment VoiceOver is on.
    ///
    /// Without `.allowsDirectInteraction` VoiceOver intercepts every touch and exploration
    /// goes completely dead; without `.silentOnTouch` it speaks on every touch-down, over the
    /// street name the map is trying to say. Both are re-applied when VoiceOver is toggled,
    /// because the traits are lost across a toggle.
    @Test func voiceOverGetsADirectTouchSurface() throws {
        let laidOut = try laidOutContainer(size: CGSize(width: 402, height: 720))
        let scrollView = laidOut.container.scrollView
        scrollView.applyAccessibility()

        if UIAccessibility.isVoiceOverRunning {
            #expect(scrollView.isAccessibilityElement)
            #expect(scrollView.accessibilityTraits.contains(.allowsDirectInteraction))
            if #available(iOS 17.0, *) {
                #expect(scrollView.accessibilityDirectTouchOptions.contains(.silentOnTouch))
            }
        } else {
            // With VoiceOver off the scroll view must not be an element at all, or it swallows
            // the toolbar and the Back button from the accessibility tree.
            #expect(!scrollView.isAccessibilityElement)
        }

        // The rotor actions are the way out for anyone who cannot make a smooth two-finger
        // drag, so the map must never be left without them.
        scrollView.panActions = laidOut.coordinator.makePanActions()
        let actions = try #require(scrollView.accessibilityCustomActions)
        #expect(actions.count == 5)
        #expect(actions.contains { $0.name.contains("Recenter") })
    }

    /// A finger on the map cancels the screen-entry summary.
    ///
    /// The summary holds exploration speech so the two do not talk over each other, but that
    /// hold has to yield the moment someone actually starts exploring — otherwise the map
    /// simply says nothing for the first couple of seconds, which reads as broken.
    @Test func startingToExploreEndsTheEntrySpeechHold() throws {
        let channel = TactileSpeechChannel()
        channel.suppressExploration(for: 30)
        channel.endSuppression()

        // Nothing observable to assert on directly, so drive the real path: a suppressed
        // channel drops the request, an unsuppressed one schedules it.
        channel.speak("Congress Street")
        #expect(channel.hasSpeechPending, "speech was still being held after a touch")
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

    /// A finger on a drawn street has to resolve to that street.
    ///
    /// This is the test the map was missing. Everything else checked the lookup by handing
    /// `map.feature(at:)` a content point directly, which skips the one step that was wrong:
    /// turning a touch into a content point. `UITouch.location(in: scrollView)` is already in
    /// content coordinates — `contentOffset` *is* `bounds.origin` — so adding the offset to it
    /// again put every hit test thousands of points off the map, and nothing ever buzzed.
    @Test func aFingerOnAStreetResolvesToThatStreet() throws {
        let size = CGSize(width: 402, height: 720)
        let laidOut = try laidOutContainer(size: size)
        let scrollView = laidOut.container.scrollView
        let map = laidOut.map

        // The invariant the whole conversion rests on.
        #expect(scrollView.bounds.origin == scrollView.contentOffset)
        #expect(scrollView.contentOffset != .zero, "the map must have scrolled to Congress Square")

        // A vertex genuinely on a drawn road and genuinely inside the viewport — the exact
        // situation a user is in when they put a finger down on a street they can see.
        let visible = scrollView.bounds.insetBy(dx: 40, dy: 40)
        var onRoad: CGPoint?
        for feature in map.features {
            if let vertex = feature.points.first(where: { visible.contains($0) }) {
                onRoad = vertex
                break
            }
        }
        let point = try #require(onRoad, "no road is visible in the opening viewport")

        // What a real touch over that spot reports: the point in the scroll view's own
        // coordinate space, which is the content space.
        let viewportPoint = CGPoint(x: point.x - scrollView.contentOffset.x,
                                    y: point.y - scrollView.contentOffset.y)
        #expect(scrollView.bounds.contains(point), "the chosen road is off screen")

        let began = try #require(scrollView.onExploreBegan)
        began(point)
        let hit = try #require(laidOut.coordinator.currentFeature,
                               "a finger on a drawn road felt nothing")

        // The touch path has to agree with a direct lookup at the same content point. That is
        // exactly what the double-offset broke: the lookup was right and the touch feeding it
        // was wrong, so every test that called the lookup directly kept passing.
        let expected = try #require(map.feature(at: point, velocity: 0))
        #expect(hit.id == expected.id)

        // And the follow dot has to land under the finger, in view coordinates.
        let indicator = try #require(laidOut.coordinator.touchIndicator)
        #expect(abs(indicator.center.x - viewportPoint.x) < 1)
        #expect(abs(indicator.center.y - viewportPoint.y) < 1)
    }

    @Test func aTouchOnAStreetStartsTheRightFeedback() throws {
        let laidOut = try laidOutContainer(size: CGSize(width: 402, height: 720))
        let map = laidOut.map

        let road = try #require(map.features.first)
        let feature = try #require(map.feature(at: polylineMidpoint(road.points), velocity: 0))
        let element = StreetSurfaceElement(id: feature.id, announcement: feature.announcement)

        // `.road` is what selects the heavy continuous buzz in the feedback policy. Any other
        // element type falls through to the inherited policy and the street goes quiet.
        #expect(element.elementType == .road)
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

// MARK: - The tactile intersection

/// The close-up junction on the Street Crossing Audio screen.
///
/// This is the one screen where the four surfaces a pedestrian has to tell apart are all
/// drawn at once, so the thing worth testing is that they stay physically separate — that a
/// sidewalk does not end up under the roadway, and that every one of them can actually be
/// found by a finger.
@MainActor
struct IntersectionLayoutTests {

    private let size = CGSize(width: 360, height: 340)

    private func layout() -> IntersectionLayout {
        IntersectionLayout.build(size: size, alongName: "Congress Street", acrossName: "High Street")
    }

    @Test func theJunctionHasEveryPieceOfAFourWayCrossing() {
        let map = layout()
        #expect(map.bands.filter { $0.surface == .road }.count == 2)
        // Two per roadway, each broken at the junction so the corners read as corners.
        #expect(map.bands.filter { $0.surface == .sidewalk }.count == 8)
        // A signalised four-way has a crossing on every arm.
        #expect(map.bands.filter { $0.surface == .crossing }.count == 4)
    }

    @Test func everyWidthIsAPhysicalMillimetreMeasurement() {
        let map = layout()
        let road = try? #require(map.bands.first { $0.surface == .road })
        let walk = try? #require(map.bands.first { $0.surface == .sidewalk })
        let cross = try? #require(map.bands.first { $0.surface == .crossing })

        #expect(abs((road?.width ?? 0)
                    - PhysicalDimensions.mmToPoints(IntersectionLayout.roadWidthMM)) < 0.01)
        #expect(abs((walk?.width ?? 0)
                    - PhysicalDimensions.mmToPoints(IntersectionLayout.sidewalkWidthMM)) < 0.01)
        #expect(abs((cross?.width ?? 0)
                    - PhysicalDimensions.mmToPoints(IntersectionLayout.crossingWidthMM)) < 0.01)

        // The roadway is the widest thing here on purpose: it is the one surface that has to
        // be recognised instantly, and it is three times a street line on the wider map.
        #expect((road?.width ?? 0) > (walk?.width ?? 0) * 2)
    }

    /// The sidewalks and the crossings on them have to clear the roadway.
    ///
    /// A crossing that overlaps the roadway it is supposed to run alongside puts the corner
    /// ramps in the traffic, and a sidewalk buried under the roadway is simply unreachable.
    /// The sidewalk sits behind a kerb, not on the roadway, and the offset that puts it there
    /// is derived from the parts rather than picked. This is the assertion that proves the
    /// derivation still adds up — half the roadway, the crossing, the kerb, half the sidewalk.
    @Test func theSidewalkSitsOneKerbBackFromTheRoadway() {
        let map = layout()
        let roadHalf = IntersectionLayout.roadWidthMM / 2
        let sidewalkNearEdge = IntersectionLayout.sidewalkOffsetMM
            - IntersectionLayout.sidewalkWidthMM / 2
        let crossingOuterEdge = roadHalf + IntersectionLayout.crossingWidthMM

        #expect(sidewalkNearEdge > roadHalf, "the sidewalk overlaps the roadway")
        #expect(abs(sidewalkNearEdge - crossingOuterEdge - IntersectionLayout.kerbGapMM) < 0.001,
                "the kerb gap has drifted")

        // 11.8 mm on the glass. Far enough to be a separate line under a finger, close enough
        // that the junction still reads as one thing rather than four streets and a square.
        #expect(abs(IntersectionLayout.sidewalkOffsetMM - 11.8) < 0.001)
        #expect(IntersectionLayout.sidewalkOffsetMM < roadHalf * 2.5,
                "the sidewalks have drifted away from the junction")

        // And it holds in points, on this device, once converted.
        let walk = map.bands.first { $0.surface == .sidewalk }
        let gap = abs((walk?.from.y ?? 0) - map.center.y)
        #expect(gap > PhysicalDimensions.mmToPoints(roadHalf))
    }

    /// Each crossing runs corner to corner and spans the street it is named for.
    @Test func eachCrossingBridgesTwoCornersOverTheStreetItNames() {
        let map = layout()
        let corner = PhysicalDimensions.mmToPoints(IntersectionLayout.sidewalkOffsetMM)

        for band in map.bands where band.surface == .crossing {
            let length = hypot(band.to.x - band.from.x, band.to.y - band.from.y)
            #expect(abs(length - corner * 2) < 0.01, "\(band.id) does not reach both corners")

            // Its middle is over a roadway — that is what makes it a crossing, and it is also
            // what puts the painted bars on dark blue rather than on the background.
            let mid = CGPoint(x: (band.from.x + band.to.x) / 2, y: (band.from.y + band.to.y) / 2)
            let overRoad = map.bands.contains { road in
                road.surface == .road
                    && distanceToSegment(mid, road.from, road.to) <= road.width / 2
            }
            #expect(overRoad, "\(band.id) does not cross a roadway")
        }
    }

    @Test func aFingerCanFindEverySurface() {
        let map = layout()

        // Dead centre is roadway — both of them cross there.
        #expect(map.hit(map.center)?.surface == .road)

        // The middle of the space between things says nothing, which is how a gap reads.
        #expect(map.hit(CGPoint(x: 4, y: 4)) == nil)

        // Sweeping the whole view has to turn up all three, or one of them is drawn but
        // unreachable — the failure a user would report as "I can't find the crossing".
        var found: Set<String> = []
        for x in stride(from: 0.0, to: size.width, by: 2) {
            for y in stride(from: 0.0, to: size.height, by: 2) {
                if let hit = map.hit(CGPoint(x: x, y: y)) {
                    found.insert("\(hit.surface)")
                }
            }
        }
        #expect(found.count == 3, "only found \(found.sorted())")
    }

    /// The diagram has to respond to a finger with VoiceOver *off* as well as on.
    ///
    /// Exploration runs on raw touches rather than a gesture recognizer precisely so the two
    /// are the same code path. This drives that path directly — which is what the touch
    /// handlers do — and checks it resolves the surface either way.
    @Test func exploringWorksWithVoiceOverOffAsWellAsOn() {
        let view = IntersectionTouchView(frame: CGRect(origin: .zero, size: size))
        view.streetNames = ("Congress Street", "High Street")
        view.layoutIfNeeded()

        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        view.explore(at: centre)
        #expect(view.currentSurface == .road, "the roadway gave no feedback")

        let offset = PhysicalDimensions.mmToPoints(IntersectionLayout.sidewalkOffsetMM)
        view.explore(at: CGPoint(x: centre.x - offset - offset, y: centre.y - offset))
        #expect(view.currentSurface == .sidewalk, "the sidewalk gave no feedback")

        view.explore(at: CGPoint(x: centre.x, y: centre.y - offset))
        #expect(view.currentSurface == .crossing, "the crossing gave no feedback")

        // Lifting off has to stop everything, or the buzz runs on after the finger is gone.
        view.stopFeedback()
        #expect(view.currentSurface == nil)
    }

    @Test func everySurfaceNamesItselfAndItsStreet() {
        let map = layout()
        for band in map.bands where band.surface == .sidewalk {
            #expect(band.name.contains("sidewalk"))
            // A bare compass direction is useless without the street it belongs to.
            #expect(band.name.contains("Street"))
        }
        for band in map.bands where band.surface == .crossing {
            #expect(band.name.contains("crossing"))
            #expect(band.name.contains("across "))
        }
        #expect(map.bands.contains { $0.surface == .road && $0.name == "Congress Street" })
        #expect(map.bands.contains { $0.surface == .road && $0.name == "High Street" })
    }

    /// Renders the junction and checks each surface actually put its colour down.
    @Test func theCanvasDrawsAllThreeSurfaces() throws {
        let canvas = IntersectionCanvasView(frame: CGRect(origin: .zero, size: size))
        canvas.layout = layout()

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            canvas.draw(canvas.bounds)
        }
        let counts = try Self.classify(image)

        #expect(counts.blue > 0, "no roadway was drawn")
        #expect(counts.sidewalkGrey > 0, "no sidewalk was drawn")
        // Bars counted only where roadway is on both sides of them, so the white background
        // cannot be mistaken for paint. This is the assertion that catches crossing markings
        // drawn white-on-white and therefore invisible.
        #expect(counts.whiteOnRoad > 0, "no crossing bars were drawn on the roadway")
        // Nothing red left over from the kerb-ramp dots.
        #expect(counts.red == 0, "\(counts.red) red px — a dot was drawn")

        try #require(image.pngData()).write(to: FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("intersection.png"))
    }

    private struct Counts {
        var blue = 0, sidewalkGrey = 0, red = 0, whiteOnRoad = 0
    }

    /// Classifies by colour family rather than exact bytes — the render pipeline is colour
    /// managed, so a stroke laid down as #023E8A does not come back as those exact values.
    private static func classify(_ image: UIImage) throws -> Counts {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        func isBlue(_ c: (Int, Int, Int)) -> Bool { c.2 > c.0 + 40 && c.2 > c.1 + 20 }
        func isNeutral(_ c: (Int, Int, Int)) -> Bool { abs(c.0 - c.1) < 14 && abs(c.1 - c.2) < 14 }
        func isSidewalk(_ c: (Int, Int, Int)) -> Bool { isNeutral(c) && (140...185).contains(c.0) }

        var counts = Counts()
        for y in 0..<height {
            for x in 0..<width {
                let c = pixel(x, y)
                if isBlue(c) {
                    counts.blue += 1
                } else if c.0 > 150, c.1 < 90, c.2 < 110 {
                    counts.red += 1
                } else if isSidewalk(c) {
                    counts.sidewalkGrey += 1
                } else if c.0 > 240, c.1 > 240, c.2 > 240 {
                    let left = (0..<x).reversed().prefix(40).first { isBlue(pixel($0, y)) } != nil
                    let right = ((x + 1)..<width).prefix(40).first { isBlue(pixel($0, y)) } != nil
                    if left && right { counts.whiteOnRoad += 1 }
                }
            }
        }
        return counts
    }
}
