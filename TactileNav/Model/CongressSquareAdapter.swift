//
//  CongressSquareAdapter.swift
//  TactileNav
//
//  Translates the TactileMapKit `TactileMapDocument` parsed from `congress_square.json`
//  (a real OpenStreetMap ODbL extract of downtown Portland, ME) into the app's render
//  models. Mirrors the approach in `RTMDocumentAdapter`: the JSON stores positions as
//  plain metres on a local grid ("1 unit = 1 metre"), not lat/lon, so we project each
//  (x, y) around the corridor's real SW-corner anchor with a simple equirectangular
//  mapping that keeps metric distances true. The base tiles are blank, so absolute
//  longitude is cosmetic — only relative geometry is shown.
//

import Foundation
import CoreLocation
import TactileMapCore

enum CongressSquareAdapter {

    struct Result {
        let corridors: [PortlandCorridor]
        let intersections: [PortlandIntersection]
        let landmarks: [PortlandLandmark]
        var all: [PortlandMapFeature] { corridors + landmarks + intersections }
    }

    // SW-corner anchor + metres-per-degree, taken from congress_square.json metadata
    // (`origin_lat` / `origin_lon`). Pinned here because the package's TactileMapMetadata
    // doesn't decode these custom keys. Regenerate the map ⇒ update these two constants.
    private static let originLatitude = 43.650248
    private static let originLongitude = -70.272557
    private static let metersPerDegreeLatitude = 111_320.0

    static func convert(_ document: TactileMapDocument) -> Result {
        let height = document.bounds.height
        let width = document.bounds.width
        let mPerDegLon = metersPerDegreeLatitude * cos(originLatitude * .pi / 180)

        func project(_ c: TactileCoordinate) -> CLLocationCoordinate2D {
            let northMeters = height - c.y            // JSON y grows south → flip north-up
            return CLLocationCoordinate2D(
                latitude: originLatitude + northMeters / metersPerDegreeLatitude,
                longitude: originLongitude + c.x / mPerDegLon
            )
        }

        var corridors: [PortlandCorridor] = []
        var intersections: [PortlandIntersection] = []
        var landmarks: [PortlandLandmark] = []

        for f in document.features {
            let custom = f.properties.custom
            switch f.elementType {
            case .corridor:
                guard case .lineString(let coords) = f.geometry, coords.count >= 2 else { continue }
                corridors.append(PortlandCorridor(
                    id: f.id,
                    name: f.properties.name,
                    level: 1,
                    accessible: f.properties.isAccessible,
                    coordinates: coords.map(project),
                    functionalClass: f.properties.category ?? "residential",
                    lanes: Int(custom["lanes"] ?? "") ?? 2,
                    oneway: (custom["oneway"] ?? "no") == "yes",
                    crossingDistanceM: Double(custom["crossing_distance_m"] ?? "") ?? 6.6
                ))

            case .intersection:
                guard case .point(let c) = f.geometry else { continue }
                let streets = (custom["streets"] ?? "")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                intersections.append(PortlandIntersection(
                    id: f.id,
                    name: f.properties.name,
                    level: 1,
                    coordinate: project(c),
                    ways: max(streets.count, f.properties.connectedCorridors?.count ?? 2),
                    signalized: (custom["signalized"] ?? "no") == "yes",
                    streets: streets
                ))

            case .landmark:
                guard case .point(let c) = f.geometry else { continue }
                let side = c.x < width / 2 ? "left" : "right"
                landmarks.append(PortlandLandmark(
                    id: f.id,
                    name: f.properties.name,
                    level: 1,
                    coordinate: project(c),
                    tag: custom["abbrev"] ?? String(f.properties.name.prefix(3)).uppercased(),
                    side: side,
                    announcement: f.properties.name,
                    category: f.properties.category ?? "place"
                ))

            default:
                continue
            }
        }

        return Result(corridors: corridors, intersections: intersections, landmarks: landmarks)
    }
}
