//
//  OSMStub.swift
//  TactileNav
//
//  A fixed place and a fixed street network, for driving the app without a network.
//
//  **Test scaffolding, and only reachable with a launch argument the app is never shipped
//  with.** It exists because the screens it stands behind now depend on two free public
//  services: a UI test that searched for real would be slow, would fail whenever Overpass was
//  queued, and would put load on donated infrastructure every time anyone ran the suite.
//
//  What it does not do is prove the real path works. Nothing here talks to OpenStreetMap, so
//  the live fetch has to be checked by hand against the real services — see the note in
//  `TactileNavUITests`.
//

import Foundation

nonisolated enum OSMStub {

    /// Present only when the app is launched by the UI tests.
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-osm-stub")
    }

    /// The one place a stubbed search finds: the junction the bundled map opens on, so a
    /// stubbed run lands somewhere a reader of this project will recognise.
    static let place = GeocodedPlace(
        id: "stub-congress-high",
        name: "Congress Street and High Street",
        context: "Portland, Cumberland County, Maine, United States",
        kind: "junction",
        latitude: 43.6537,
        longitude: -70.2635)

    static func search(_ query: String) -> [GeocodedPlace] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 ? [place] : []
    }

    /// A crossroads of two named streets, plus one of every other kind of line, so the feature
    /// toggles have something to switch on.
    static func overpassReply() -> Data {
        let lat = place.latitude, lon = place.longitude
        let step = 0.002
        func way(_ id: Int, _ nodes: [Int], _ points: [(Double, Double)],
                 _ tags: [String: String]) -> String {
            let geometry = points.map { "{\"lat\":\($0.0),\"lon\":\($0.1)}" }.joined(separator: ",")
            let tagList = tags.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
            return "{\"type\":\"way\",\"id\":\(id),\"nodes\":[\(nodes.map(String.init).joined(separator: ","))],"
                + "\"geometry\":[\(geometry)],\"tags\":{\(tagList)}}"
        }
        let ways = [
            way(1, [1, 2, 3], [(lat, lon - step), (lat, lon), (lat, lon + step)],
                ["highway": "primary", "name": "Congress Street"]),
            way(2, [4, 2, 5], [(lat - step, lon), (lat, lon), (lat + step, lon)],
                ["highway": "secondary", "name": "High Street"]),
            way(3, [6, 7], [(lat + 0.0004, lon - step), (lat + 0.0004, lon + step)],
                ["highway": "footway", "footway": "sidewalk"]),
            way(4, [8, 9], [(lat + 0.0002, lon + 0.0003), (lat - 0.0002, lon + 0.0003)],
                ["highway": "footway", "footway": "crossing"]),
            way(5, [10, 11], [(lat - 0.0006, lon - step), (lat - 0.0006, lon + step)],
                ["highway": "service"]),
            way(6, [12, 13], [(lat - 0.0012, lon - step), (lat - 0.0012, lon + step)],
                ["railway": "rail", "name": "Portland Line"]),
        ]
        return Data("{\"elements\":[\(ways.joined(separator: ","))]}".utf8)
    }
}
