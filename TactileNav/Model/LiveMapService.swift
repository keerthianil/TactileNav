//
//  LiveMapService.swift
//  TactileNav
//
//  Getting a tactile map of anywhere: geocode, fetch, build, keep.
//
//  Two maps in this app, two different promises. Congress Square ships as a file and is the one
//  a study is run on: fixed, offline, never changing underfoot. Everything else is fetched when
//  asked for, because there is no list of everywhere.
//
//  **Fetched once, kept for good.** The built document is written to disk in the same JSON the
//  bundled maps use, so opening a postcode a second time needs no network at all. That is not
//  an optimisation: a session in the field cannot depend on a free, donated, frequently queued
//  public service answering at the moment a participant is sitting down. Fetch it beforehand,
//  and it is there.
//

import CoreText
import Foundation
import TactileMapCore
import UIKit

nonisolated struct LiveMapService {

    /// Half the side of the square fetched around a searched point: 1.5 km, so 3 km across.
    ///
    /// Sized against what is actually usable rather than what is possible. A postcode is often
    /// larger than this, and fetching all of one would mean a bigger wait for ground nobody
    /// pans to — 3 km across is already fifteen screens wide at the middle scale. It is also
    /// about where Overpass stays quick: this box comes back in a few seconds where twice the
    /// side is four times the data.
    static let halfSpanMeters: Double = 1_500

    /// Roughly how much ground that is, for saying out loud.
    static var spanDescription: String { "about 3 kilometres across" }

    enum Failure: LocalizedError {
        case tooFarNorth

        var errorDescription: String? {
            switch self {
            case .tooFarNorth:
                return "Maps this close to the pole cannot be drawn flat."
            }
        }
    }

    // MARK: Fetching

    /// The document for a place: from disk if it has been fetched before, otherwise from
    /// OpenStreetMap, and written to disk on the way back.
    ///
    /// Returns whether it came from the network, so the caller can say so — "fetched" and
    /// "already had it" are different experiences and worth distinguishing out loud.
    static func document(for place: GeocodedPlace) async throws
        -> (document: TactileMapDocument, box: OSMDocumentBuilder.Box, fetched: Bool) {

        // The flat projection is a cosine away from breaking down; well before the pole it
        // stops being honest to draw a square of ground as a square.
        guard abs(place.latitude) < 80 else { throw Failure.tooFarNorth }

        let box = OSMDocumentBuilder.Box(centreLatitude: place.latitude,
                                         centreLongitude: place.longitude,
                                         halfSpanMeters: halfSpanMeters)

        if let cached = cachedDocument(for: place) {
            return (cached, box, false)
        }

        let data: Data
        if OSMStub.isActive {
            data = OSMStub.overpassReply()
        } else {
            let query = OverpassClient.streetNetworkQuery(
                south: box.south, west: box.west, north: box.north, east: box.east)
            data = try await OverpassClient.run(query)
        }
        let document = try OSMDocumentBuilder.build(overpass: data, box: box, name: place.name)
        // A stubbed run is a test, and its made-up streets have no business surviving into a
        // real one's cache.
        if !OSMStub.isActive { cache(document, for: place) }
        return (document, box, true)
    }

    /// The finished map, ready to put a finger on.
    ///
    /// `context` has to be made on the main actor — it carries the screen's physical metrics and
    /// the label font — and everything after it is deliberately off it: parsing a few thousand
    /// ways and building four spatial indices is a dropped frame otherwise.
    static func map(for place: GeocodedPlace,
                    context: PortlandMapLoader.LoadContext,
                    features: MapFeatureSet) async throws -> (map: StreetMap, fetched: Bool) {
        let (document, box, fetched) = try await document(for: place)
        let centre = box.project(latitude: place.latitude, longitude: place.longitude)

        let map = StreetMap.build(
            document: document,
            // The searched point, so the map opens on what was asked for rather than on the
            // middle of the box. `StreetMap.build` then snaps it to the nearest junction, which
            // is a better place to land a first finger than a spot mid-block.
            extras: StreetMapExtras(initialCenter: .init(x: Double(centre.x), y: Double(centre.y))),
            metrics: context.metrics,
            labelFont: context.labelFont,
            features: features)
        return (map, fetched)
    }

    // MARK: Keeping

    /// One file per place and span. The coordinates inside a document are relative to the box
    /// it was cut to, so a document is only reusable for the same centre at the same span —
    /// hence both in the key.
    private static func cacheURL(for place: GeocodedPlace) -> URL? {
        guard let directory = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let maps = directory.appendingPathComponent("OSMMaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        let key = String(format: "%.5f_%.5f_%.0f", place.latitude, place.longitude, halfSpanMeters)
        return maps.appendingPathComponent("map_\(key).json")
    }

    private static func cachedDocument(for place: GeocodedPlace) -> TactileMapDocument? {
        guard let url = cacheURL(for: place),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TactileMapDocument.self, from: data)
    }

    private static func cache(_ document: TactileMapDocument, for place: GeocodedPlace) {
        guard let url = cacheURL(for: place),
              let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Whether this place is already on disk — so the options screen can say whether pressing
    /// Create Map means a wait or not.
    static func isCached(_ place: GeocodedPlace) -> Bool {
        guard let url = cacheURL(for: place) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
