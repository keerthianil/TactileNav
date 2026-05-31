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

    init(condition: StudyCondition) {
        self.document = try! TactileMapDocument.load(from: condition.mapFileName, bundle: .main)
        self.policy   = condition.makeFeedbackPolicy()

        let sessionName = condition.shortLogName
        self.logger = CSVTouchLogger(fileNameGenerator: { metadata in
            let name = metadata["sessionName"] ?? sessionName
            let now  = Date()
            let df   = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyyMMdd"
            let datePart = df.string(from: now)
            df.dateFormat = "HHmmss"
            let timePart = df.string(from: now)
            let version  = CSVTouchLogger.nextVersion()
            return "\(name)_\(datePart)_\(timePart)_v\(version)"
        })
        self.logger.startSession(metadata: ["sessionName": sessionName])
    }

    /// Load any map by filename without a study condition. Uses NL feedback by default.
    init(mapFileName: String) {
        self.document = try! TactileMapDocument.load(from: mapFileName, bundle: .main)
        self.policy   = NLFeedbackService()

        let sessionName = "CustomMap_\(mapFileName)"
        self.logger = CSVTouchLogger(fileNameGenerator: { metadata in
            let name = metadata["sessionName"] ?? sessionName
            let now  = Date()
            let df   = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyyMMdd_HHmmss"
            return "\(name)_\(df.string(from: now))"
        })
        self.logger.startSession(metadata: ["sessionName": sessionName])
    }
}

// MARK: - Version helper (mirrors CSVTouchLogger.getNextSessionNumber)

extension CSVTouchLogger {
    static func nextVersion() -> Int {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return 1 }
        let pattern = try! NSRegularExpression(pattern: #"_v(\d+)\.csv$"#)
        var max = 0
        for url in contents where url.pathExtension == "csv" {
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if let match = pattern.firstMatch(in: name, range: range),
               let vRange = Range(match.range(at: 1), in: name),
               let v = Int(name[vRange]) {
                if v > max { max = v }
            }
        }
        return max + 1
    }
}
