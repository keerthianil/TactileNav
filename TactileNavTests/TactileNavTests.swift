//
//  TactileNavTests.swift
//  TactileNavTests
//
//  Exercises the Congress Square map through its real pipeline: the bundled
//  OpenStreetMap extract, the projection into content points, and the hit testing a
//  finger relies on.
//

import CoreText
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

    @Test func roadWidthScalesWithLaneCountFromTheLaneConstant() throws {
        let map = try loadMap()
        let lane = map.metrics.laneWidthPoints

        for feature in map.features where feature.surface == .road {
            // Each road is a whole number of lanes wide, floored at one.
            let lanes = max(feature.lanes, 1)
            #expect(abs(feature.strokeWidth - lane * CGFloat(lanes)) < 0.01,
                    "\(feature.id): \(feature.strokeWidth) is not \(lanes) lanes")
            #expect(feature.strokeWidth >= lane)
        }

        // A multi-lane arterial must be visibly wider than a two-lane side street.
        let widths = Set(map.features.filter { $0.surface == .road }.map(\.strokeWidth))
        #expect(widths.count > 1, "every road is the same width")
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
        // Roads are several lanes wide here and sidewalks are one, so roads must dominate.
        #expect(tally.blue > tally.grey)
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
