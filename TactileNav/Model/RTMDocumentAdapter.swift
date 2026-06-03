//
//  RTMDocumentAdapter.swift
//  TactileNav  (RouxTactileMap)
//
//  THIS FILE IS
//  A translator. The bundled file `roux_portland.json` describes the map, but in a
//  shape our map view doesn't directly understand. This file reads that JSON
//  (already parsed into a TactileMapDocument by the package) and turns it into our
//  simple lists: RTMDiscoveredStreet, RTMDiscoveredIntersection, RTMDiscoveredPOI.
//
//  THE ONE TRICKY PART — coordinates
//  The JSON stores positions as plain meters on a little 771×660 grid ("1 unit = 1
//  meter"), NOT as real-world latitude/longitude. A real Apple map needs lat/lon. So
//  we convert: take each (x, y) in meters and place it around the Roux Institute's
//  real center point. We do this conversion ourselves (a simple, even "equirectangular"
//  mapping) instead of using the package's built-in transform, because that one
//  stretches everything vertically by 2.6× and parks the map near the ocean at (0,0).
//  Doing it ourselves keeps distances true, so the map looks right and the
//  buzz/snapping (which think in meters) stay accurate.
//

import Foundation
import CoreLocation
import TactileMapCore

enum RTMDocumentAdapter {

    /// Unified output — Sendable so it can be produced off the main actor.
    struct Result: Sendable {
        let streets: [RTMDiscoveredStreet]
        let intersections: [RTMDiscoveredIntersection]
        let pois: [RTMDiscoveredPOI]
    }

    // Roux Institute area center (from roux_portland.json metadata `center_lat`,
    // which the package's TactileMapMetadata doesn't decode, so it's pinned here).
    // Longitude is cosmetic — the base tiles are blank, so only relative geometry
    // matters; we just need a metric-consistent projection.
    private static let originLatitude: Double = 43.679992
    private static let originLongitude: Double = -70.2557
    private static let metersPerDegreeLatitude: Double = 111_320.0

    /// The JSON's y grows downward (screen/Canvas convention); flip it so north is up.
    /// If the map ever renders upside-down, set this to false.
    private static let flipNorthUp = true

    // MARK: - Conversion

    static func convert(_ document: TactileMapDocument) -> Result {
        let height = document.bounds.height
        let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(originLatitude * .pi / 180)

        func project(_ c: TactileCoordinate) -> CLLocationCoordinate2D {
            let northMeters = flipNorthUp ? (height - c.y) : c.y
            return CLLocationCoordinate2D(
                latitude: originLatitude + northMeters / metersPerDegreeLatitude,
                longitude: originLongitude + c.x / metersPerDegreeLongitude
            )
        }

        var streets: [RTMDiscoveredStreet] = []
        var intersections: [RTMDiscoveredIntersection] = []
        var pois: [RTMDiscoveredPOI] = []

        for feature in document.features {
            switch feature.elementType {
            case .corridor:
                guard case .lineString(let coords) = feature.geometry, coords.count >= 2 else { continue }
                streets.append(RTMDiscoveredStreet(
                    id: feature.id,
                    name: feature.properties.name,
                    coordinates: coords.map(project),
                    roadType: roadType(for: feature.properties.category)
                ))

            case .intersection:
                guard case .point(let coord) = feature.geometry else { continue }
                intersections.append(RTMDiscoveredIntersection(
                    id: feature.id,
                    name: feature.properties.name,
                    coordinate: project(coord),
                    connectedStreetIDs: feature.properties.connectedCorridors ?? []
                ))

            case .landmark:
                // Skip non-place landmarks (crossings, traffic signals) — see poiCategory.
                guard case .point(let coord) = feature.geometry,
                      let category = poiCategory(for: feature.properties.category) else { continue }
                pois.append(RTMDiscoveredPOI(
                    id: feature.id,
                    name: feature.properties.name,
                    coordinate: project(coord),
                    category: category,
                    address: nil
                ))

            default:
                continue
            }
        }

        return Result(streets: streets, intersections: intersections, pois: pois)
    }

    // MARK: - Category mapping

    private static func roadType(for category: String?) -> RTMRoadType {
        switch category?.lowercased() {
        case "primary", "secondary", "tertiary", "trunk":      return .primary
        case "residential", "unclassified", "living_street", "road": return .residential
        case "service":                                         return .service
        case "footway", "pedestrian":                           return .footway
        case "path", "track", "bridleway":                      return .path
        case "cycleway":                                        return .cycleway
        case "steps":                                           return .steps
        default:                                                return .residential
        }
    }

    /// Returns nil for things that aren't real points of interest (crossings,
    /// traffic signals, or an untagged landmark) so they're skipped.
    private static func poiCategory(for category: String?) -> RTMPOICategory? {
        switch category?.lowercased() {
        case "restaurant", "fast_food", "bar", "pub":  return .restaurant
        case "cafe":                                    return .cafe
        case "university", "college", "anchor":         return .university
        case "school", "kindergarten":                  return .school
        case "hospital", "clinic":                      return .hospital
        case "pharmacy":                                return .pharmacy
        case "bank", "atm":                             return .bank
        case "library":                                 return .library
        case "parking":                                 return .parking
        case "park", "garden":                          return .park
        case "store", "shop":                           return .store
        case "bus_stop", "transit", "ferry_terminal":   return .transit
        case "slipway", "marina":                       return .boatLaunch
        case "crossing", "traffic_signal", nil:         return nil   // not places → skip
        default:                                        return .namedPlace
        }
    }
}
