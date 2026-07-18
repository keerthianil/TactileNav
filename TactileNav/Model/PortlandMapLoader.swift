import Foundation
import MapKit
import TactileMapCore

enum PortlandMapLoader {

    static func loadLevel1Features(from filename: String = "portland_congress_square") -> [PortlandMapFeature] {
        guard let json = loadJSON(filename: filename) else { return [] }
        guard let features = json["features"] as? [[String: Any]] else { return [] }

        var result: [PortlandMapFeature] = []

        for feature in features {
            guard let id = feature["id"] as? String,
                  let type = feature["type"] as? String,
                  let geometry = feature["geometry"] as? [String: Any],
                  let properties = feature["properties"] as? [String: Any] else {
                continue
            }

            let name = properties["name"] as? String ?? ""
            let level = properties["level"] as? Int ?? 1

            switch type {
            case "corridor":
                if let coordArrays = geometry["coordinates"] as? [[Double]] {
                    let coords = coordArrays.map { pair -> CLLocationCoordinate2D in
                        portlandGridToCoordinate(x: pair[0], y: pair[1])
                    }
                    let accessible = properties["accessible"] as? Bool ?? true
                    result.append(PortlandCorridor(
                        id: id, name: name, level: level,
                        accessible: accessible, coordinates: coords
                    ))
                }

            case "intersection":
                if let coordArray = geometry["coordinates"] as? [Double], coordArray.count >= 2 {
                    let coord = portlandGridToCoordinate(x: coordArray[0], y: coordArray[1])
                    let ways = properties["ways"] as? Int ?? 4
                    result.append(PortlandIntersection(
                        id: id, name: name, level: level,
                        coordinate: coord, ways: ways
                    ))
                }

            case "landmark":
                if let coordArray = geometry["coordinates"] as? [Double], coordArray.count >= 2 {
                    let coord = portlandGridToCoordinate(x: coordArray[0], y: coordArray[1])
                    let tag = properties["tag"] as? String ?? ""
                    let side = properties["side"] as? String ?? "right"
                    let announcement = properties["announcement"] as? String ?? name
                    let category = properties["category"] as? String ?? ""
                    result.append(PortlandLandmark(
                        id: id, name: name, level: level,
                        coordinate: coord, tag: tag, side: side,
                        announcement: announcement, category: category
                    ))
                }

            default:
                break
            }
        }

        return result
    }

    static func loadLevel2Features(for intersectionId: String) -> [PortlandMapFeature] {
        let filename = "intersection_\(intersectionId)_detail"
        guard let json = loadJSON(filename: filename) else { return [] }
        guard let features = json["features"] as? [[String: Any]] else { return [] }

        var result: [PortlandMapFeature] = []

        for feature in features {
            guard let id = feature["id"] as? String,
                  let type = feature["type"] as? String,
                  let geometry = feature["geometry"] as? [String: Any],
                  let properties = feature["properties"] as? [String: Any] else {
                continue
            }

            let name = properties["name"] as? String ?? ""
            let level = properties["level"] as? Int ?? 2

            switch type {
            case "corridor":
                if let coordArrays = geometry["coordinates"] as? [[Double]] {
                    let coords = coordArrays.map { pair -> CLLocationCoordinate2D in
                        portlandGridToCoordinate(x: pair[0], y: pair[1])
                    }
                    result.append(PortlandCorridor(
                        id: id, name: name, level: level,
                        accessible: true, coordinates: coords
                    ))
                }

            case "intersection":
                if let coordArray = geometry["coordinates"] as? [Double], coordArray.count >= 2 {
                    let coord = portlandGridToCoordinate(x: coordArray[0], y: coordArray[1])
                    result.append(PortlandIntersection(
                        id: id, name: name, level: level,
                        coordinate: coord
                    ))
                }

            case "landmark":
                if let coordArray = geometry["coordinates"] as? [Double], coordArray.count >= 2 {
                    let coord = portlandGridToCoordinate(x: coordArray[0], y: coordArray[1])
                    let tag = properties["tag"] as? String ?? ""
                    let side = properties["side"] as? String ?? "right"
                    let announcement = properties["announcement"] as? String ?? name
                    let category = properties["category"] as? String ?? ""
                    result.append(PortlandLandmark(
                        id: id, name: name, level: level,
                        coordinate: coord, tag: tag, side: side,
                        announcement: announcement, category: category
                    ))
                }

            case "sidewalk":
                if let coordArrays = geometry["coordinates"] as? [[Double]] {
                    let coords = coordArrays.map { pair -> CLLocationCoordinate2D in
                        portlandGridToCoordinate(x: pair[0], y: pair[1])
                    }
                    result.append(PortlandSidewalk(
                        id: id, name: name, level: level,
                        coordinates: coords
                    ))
                }

            case "crosswalk":
                if let coordArrays = geometry["coordinates"] as? [[Double]] {
                    let coords = coordArrays.map { pair -> CLLocationCoordinate2D in
                        portlandGridToCoordinate(x: pair[0], y: pair[1])
                    }
                    result.append(PortlandCrosswalk(
                        id: id, name: name, level: level,
                        coordinates: coords
                    ))
                }

            default:
                break
            }
        }

        return result
    }

    static func loadAPSData() -> [PortlandAPSLocation] {
        guard let json = loadJSON(filename: "portland_aps_data") else { return [] }
        guard let apsArray = json["aps_locations"] as? [[String: Any]] else { return [] }

        do {
            let data = try JSONSerialization.data(withJSONObject: apsArray)
            return try JSONDecoder().decode([PortlandAPSLocation].self, from: data)
        } catch {
            return []
        }
    }

    static func loadTrafficData() -> (segments: [PortlandTrafficSegment], intersections: [PortlandTrafficIntersection]) {
        guard let json = loadJSON(filename: "portland_traffic_data") else {
            return ([], [])
        }

        var segments: [PortlandTrafficSegment] = []
        var intersections: [PortlandTrafficIntersection] = []

        if let segArray = json["road_segments"] as? [[String: Any]] {
            do {
                let data = try JSONSerialization.data(withJSONObject: segArray)
                segments = try JSONDecoder().decode([PortlandTrafficSegment].self, from: data)
            } catch { }
        }

        if let intArray = json["intersections"] as? [[String: Any]] {
            do {
                let data = try JSONSerialization.data(withJSONObject: intArray)
                intersections = try JSONDecoder().decode([PortlandTrafficIntersection].self, from: data)
            } catch { }
        }

        return (segments, intersections)
    }

    private static func loadJSON(filename: String) -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: filename, withExtension: "json") else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}
