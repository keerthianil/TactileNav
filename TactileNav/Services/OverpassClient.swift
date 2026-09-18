//
//  OverpassClient.swift
//  TactileNav
//
//  Fetching a street network from OpenStreetMap, live.
//
//  The Congress Square map ships as a file built ahead of time, which is right for the one map
//  a study is run on: it never changes underfoot and it works with no signal. Everywhere else
//  has to come down the wire, because there is no list of everywhere.
//
//  Two endpoints, tried in turn. Overpass is free infrastructure run on donated hardware and it
//  queues under load — one of the probes while building this took three seconds and another
//  sixteen for a smaller area. So the timeout is generous, the failure messages say what to do,
//  and anything successfully fetched is written to disk so the same place never has to be
//  fetched twice.
//

import Foundation

nonisolated struct OverpassClient {

    enum Failure: LocalizedError {
        case offline
        case unavailable
        case tooBusy

        var errorDescription: String? {
            switch self {
            case .offline:
                return "No internet connection. Fetching a new map needs one."
            case .unavailable:
                return "OpenStreetMap's map service is not responding. Try again in a moment."
            case .tooBusy:
                return "OpenStreetMap's map service is busy. Try again in a minute."
            }
        }
    }

    private static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
    ]

    /// Runs a query, falling back to the second server if the first will not answer.
    ///
    /// Forty-five seconds each rather than the three minutes Overpass itself allows. A healthy
    /// answer to the query below comes back in two or three seconds and a queued one in fifteen,
    /// so a longer wait is not patience, it is a screen that says "downloading" for minutes with
    /// nothing coming — which is what the first version did, and it reads as a hang.
    static func run(_ query: String) async throws -> Data {
        var lastFailure: Failure = .unavailable

        for endpoint in endpoints {
            var request = URLRequest(url: URL(string: endpoint)!, timeoutInterval: 45)
            request.httpMethod = "POST"
            request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
                .data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue(OSMGeocoder.userAgent, forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return data }
                switch http.statusCode {
                case 200..<300:
                    return data
                // Overpass says "too many requests" and "gateway timeout" when it is swamped.
                case 429, 504:
                    lastFailure = .tooBusy
                default:
                    lastFailure = .unavailable
                }
            } catch let error as URLError where error.code == .notConnectedToInternet
                                            || error.code == .networkConnectionLost {
                // No point trying the second server without a network.
                throw Failure.offline
            } catch {
                lastFailure = .unavailable
            }
        }
        throw lastFailure
    }

    // MARK: The query

    /// Every kind of line the app can draw, inside a bounding box.
    ///
    /// Asked for in one request rather than one per category, because the reader may switch a
    /// category on after the map is built and going back to the network for it would mean a
    /// wait in the middle of reading. What is fetched is everything; what is *drawn* is decided
    /// afterwards, on the device — see `MapFeatureSet`.
    ///
    /// Footways are keyed on `highway` rather than on the optional `footway` subtag, for the
    /// same reason the offline builder is: keying on `footway=sidewalk` alone silently drops
    /// most of the pavement, which is how a run of junctions ended up with no kerbs.
    static func streetNetworkQuery(south: Double, west: Double,
                                   north: Double, east: Double) -> String {
        let box = String(format: "%.6f,%.6f,%.6f,%.6f", south, west, north, east)
        let roads = OSMTags.roadClasses.joined(separator: "|")
        let rails = OSMTags.railwayClasses.joined(separator: "|")
        return """
        [out:json][timeout:180];
        (
          way["highway"~"^(\(roads))$"](\(box));
          way["highway"="footway"](\(box));
          way["highway"="pedestrian"](\(box));
          way["footway"="crossing"](\(box));
          way["highway"="service"](\(box));
          way["railway"~"^(\(rails))$"](\(box));
        );
        out body geom;
        """
    }
}
