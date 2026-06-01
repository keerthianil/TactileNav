import Foundation
import Combine
import TactileMapCore
import TactileMapFeedback
import TactileMapLogging

@MainActor
final class MapViewModel: ObservableObject {

    let document: TactileMapDocument
    let policy: any FeedbackPolicy
    let logger: CSVTouchLogger

    /// Load any map by filename. Uses Natural-Language feedback by default.
    /// The CSV log is named after the map (from its metadata) plus a
    /// readable timestamp, e.g. `Roux_Institute_Area_Portland_ME_20260531_194300`.
    init(mapFileName: String) {
        let doc = try! TactileMapDocument.load(from: mapFileName, bundle: .main)
        self.document = doc
        self.policy   = NLFeedbackService()

        let sessionName = Self.sessionName(for: doc, fallback: mapFileName)
        self.logger = CSVTouchLogger(fileNameGenerator: { metadata in
            let name = metadata["sessionName"] ?? sessionName
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            let now = Date()
            df.dateFormat = "yyyyMMdd"
            let datePart = df.string(from: now)
            df.dateFormat = "HHmmss"
            let timePart = df.string(from: now)
            return "\(name)_\(datePart)_\(timePart)"
        })
        self.logger.startSession(metadata: ["sessionName": sessionName])
    }

    /// Builds a filesystem-safe session name from the map's display name.
    private static func sessionName(for doc: TactileMapDocument, fallback: String) -> String {
        let raw = doc.metadata?.name ?? fallback
        let allowed = CharacterSet.alphanumerics
        var out = ""
        for scalar in raw.unicodeScalars {
            out.append(allowed.contains(scalar) ? Character(scalar) : "_")
        }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? fallback : trimmed
    }
}
