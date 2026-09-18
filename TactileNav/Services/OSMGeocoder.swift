//
//  OSMGeocoder.swift
//  TactileNav
//
//  Turning what somebody typed into a place on the earth, using OpenStreetMap's own geocoder.
//
//  Nominatim rather than Apple's `CLGeocoder` for one reason: the map is drawn from
//  OpenStreetMap, so the search had better agree with it. Ask Apple where a street is and you
//  can be handed a point that has no corresponding way in the data we then fetch — the map
//  opens somewhere plausible with nothing at the centre of it.
//
//  **Postcodes are the coarsest thing worth searching for and the most useful.** A reader
//  planning a trip knows the district they are going to long before they know which corner of
//  it, and a postcode is how people say that. It is also ambiguous worldwide — 02119 is a
//  neighbourhood of Boston, a district of Vilnius and one of Seoul — so results carry their
//  full place name and the reader picks. Guessing a country for them would be wrong more often
//  than it was helpful, and silently wrong at that.
//

import Foundation

// MARK: - A place somebody could go

nonisolated struct GeocodedPlace: Identifiable, Hashable, Sendable {
    let id: String
    /// "02119, Roxbury, Boston" — the short head of the name, for a heading.
    let name: String
    /// "Suffolk County, Massachusetts, United States" — the rest, for telling two apart.
    let context: String
    /// What OpenStreetMap calls it: postcode, road, suburb, house…
    let kind: String
    let latitude: Double
    let longitude: Double

    /// One line for VoiceOver: the whole name, said once.
    var spokenLabel: String {
        context.isEmpty ? name : "\(name). \(context)"
    }
}

// MARK: - The geocoder

nonisolated struct OSMGeocoder {

    enum Failure: LocalizedError {
        case offline
        case unavailable
        case nothingFound(String)

        var errorDescription: String? {
            switch self {
            case .offline:
                return "No internet connection. Searching a new place needs one."
            case .unavailable:
                return "OpenStreetMap's search is not responding. Try again in a moment."
            case .nothingFound(let query):
                return "Nothing called \"\(query)\" was found."
            }
        }
    }

    /// Nominatim asks that every client identify itself and keep to about one call a second.
    /// Both are easy here: a search is something a person types, not something that loops.
    static let userAgent = "TactileNav/1.0 (accessibility research; UNAR Labs, Northeastern University)"

    private static let endpoint = "https://nominatim.openstreetmap.org/search"

    /// Look up whatever was typed — a postcode, a street, a place, an address.
    static func search(_ query: String, limit: Int = 12) async throws -> [GeocodedPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        // Only ever true under the UI tests — see `OSMStub`.
        if OSMStub.isActive { return OSMStub.search(trimmed) }

        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "limit", value: String(limit)),
            // Keeps the response small: the geometry we need comes from Overpass, not here.
            URLQueryItem(name: "polygon_geojson", value: "0"),
        ]
        guard let url = components.url else { throw Failure.unavailable }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw Failure.unavailable
            }
            data = body
        } catch let error as Failure {
            throw error
        } catch let error as URLError where error.code == .notConnectedToInternet
                                        || error.code == .networkConnectionLost {
            throw Failure.offline
        } catch {
            throw Failure.unavailable
        }

        let places = try places(fromNominatimJSON: data)
        guard !places.isEmpty else { throw Failure.nothingFound(trimmed) }
        return places
    }

    /// The parsing, split out from the request so it can be tested without a network.
    static func places(fromNominatimJSON data: Data) throws -> [GeocodedPlace] {
        try JSONDecoder().decode([Response].self, from: data)
            .compactMap(GeocodedPlace.init(response:))
    }

    // MARK: Decoding

    struct Response: Decodable {
        let place_id: Int?
        let osm_type: String?
        let osm_id: Int?
        let lat: String
        let lon: String
        let display_name: String
        let addresstype: String?
        let type: String?
    }
}

extension GeocodedPlace {
    /// Nominatim gives one long comma-separated name. The first two parts are what identifies
    /// the place; the rest is what tells two places with the same name apart, so they are kept
    /// but held back — a reader hears "02119, Roxbury" before "Suffolk County, Massachusetts".
    init?(response: OSMGeocoder.Response) {
        guard let latitude = Double(response.lat), let longitude = Double(response.lon) else {
            return nil
        }
        let parts = response.display_name
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        self.init(
            id: "\(response.osm_type ?? "n")-\(response.osm_id ?? response.place_id ?? 0)-\(response.lat),\(response.lon)",
            name: parts.prefix(2).joined(separator: ", "),
            context: parts.dropFirst(2).joined(separator: ", "),
            kind: response.addresstype ?? response.type ?? "place",
            latitude: latitude,
            longitude: longitude)
    }
}
