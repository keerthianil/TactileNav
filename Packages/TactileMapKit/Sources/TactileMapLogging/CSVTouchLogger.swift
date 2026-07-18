import Foundation
import UIKit

// MARK: - CSV Touch Logger

/// A ``TouchLogger`` that writes events to a CSV file in the app's Documents
/// directory.
///
/// - Touch-down and touch-up events are always logged.
/// - Touch-move events are throttled to ``samplingInterval`` (default 100 ms).
/// - Each session produces one `.csv` file whose name is controlled by
///   ``fileNameGenerator``.
@MainActor
public final class CSVTouchLogger: TouchLogger {

    // MARK: Session state

    private var sessionStartTime: Date?
    private var lastLogTime: Date?
    private var currentFileName: String?
    private var currentMetadata: [String: String] = [:]
    private var customKeys: [String] = []

    // MARK: Configuration

    /// Minimum interval between successive touch-move writes.
    public let samplingInterval: TimeInterval

    /// Closure that produces a file name (without extension) from session
    /// metadata.
    public let fileNameGenerator: @MainActor ([String: String]) -> String

    // MARK: Formatters

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let fileTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: Init

    /// Creates a new CSV touch logger.
    ///
    /// - Parameters:
    ///   - samplingInterval: Minimum time between logged move events
    ///     (default 0.1 s).
    ///   - fileNameGenerator: Closure that builds a file name from session
    ///     metadata.  The default generator produces
    ///     `Session_{yyyyMMdd}_{HHmmss}_v{N}`.
    public init(
        samplingInterval: TimeInterval = 0.1,
        fileNameGenerator: @escaping @MainActor ([String: String]) -> String = CSVTouchLogger.defaultFileNameGenerator
    ) {
        self.samplingInterval = samplingInterval
        self.fileNameGenerator = fileNameGenerator
    }

    // MARK: - TouchLogger conformance

    public func startSession(metadata: [String: String]) {
        let now = Date()
        sessionStartTime = now
        lastLogTime = nil
        currentMetadata = metadata

        let baseName = fileNameGenerator(metadata)
        currentFileName = baseName + ".csv"

        // Determine custom column keys (sorted for deterministic ordering).
        customKeys = metadata.keys.sorted()

        // Build CSV header.
        var header = "Time Stamp,Trial Time,Touch Event,Object Type,Touch X,Touch Y"
        for key in customKeys {
            header += ",\(key)"
        }
        header += "\n"

        // Write the header to a new file.
        let fileURL = documentURL(for: currentFileName!)
        try? header.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    public func endSession() {
        sessionStartTime = nil
        lastLogTime = nil
        currentFileName = nil
        currentMetadata = [:]
        customKeys = []
    }

    @discardableResult
    public func logEvent(_ event: TouchEvent) -> Bool {
        guard isSessionActive, let fileName = currentFileName else { return false }

        // Always log touchDown and touchUp; throttle touchMove.
        if event.eventType == .touchMove {
            if let last = lastLogTime,
               event.timestamp.timeIntervalSince(last) < samplingInterval {
                return false
            }
        }

        lastLogTime = event.timestamp

        // Determine the custom keys for this event. If the event carries
        // keys we haven't seen yet, they won't appear in the header, so we
        // use only the keys established at session start.  Additional keys
        // from the event's own custom dictionary are appended in sorted
        // order.
        let allKeys: [String]
        let extraKeys = event.custom.keys.sorted().filter { !customKeys.contains($0) }
        if extraKeys.isEmpty {
            allKeys = customKeys
        } else {
            allKeys = customKeys + extraKeys
            // NOTE: extra keys won't have a header column unless the caller
            // included them in the session metadata.
        }

        let timestampString = Self.timestampFormatter.string(from: event.timestamp)
        let trialTimeString = formatTrialTime(event.sessionElapsed)
        let objectType = event.elementType?.rawValue ?? event.elementName
        let touchX = String(format: "%.1f", event.touchPoint.x)
        let touchY = String(format: "%.1f", event.touchPoint.y)

        var line = "\(timestampString),\(trialTimeString),\(event.eventType.rawValue),\(objectType),\(touchX),\(touchY)"

        for key in allKeys {
            let value = event.custom[key] ?? ""
            line += ",\(value)"
        }
        line += "\n"

        appendToCSV(line, fileName: fileName)
        return true
    }

    public var isSessionActive: Bool {
        sessionStartTime != nil
    }

    // MARK: - File management

    /// Returns URLs for all CSV log files, sorted newest first.
    public func getAllLogFiles() -> [URL] {
        let documentsURL = Self.documentsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        let csvFiles = contents.filter { $0.pathExtension == "csv" }

        return csvFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    /// Deletes the file at the given URL.
    ///
    /// - Returns: `true` if the file was removed successfully.
    @discardableResult
    public func deleteFile(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    /// Human-readable file size (e.g. "12 KB").
    public func getFileSize(at url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return "—"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    /// Presents the system share sheet for the given file.
    public func shareFile(at url: URL, from viewController: UIViewController) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        // iPad popover support.
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = viewController.view
            popover.sourceRect = CGRect(
                x: viewController.view.bounds.midX,
                y: viewController.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }

        viewController.present(activityVC, animated: true)
    }

    // MARK: - Default file name generator

    /// Produces `Session_{yyyyMMdd}_{HHmmss}_v{N}` where *N* is one past
    /// the highest session number found among existing CSV files.
    public static func defaultFileNameGenerator(_ metadata: [String: String]) -> String {
        let now = Date()
        let datePart = fileTimestampFormatter.string(from: now)
        let timePart = fileTimeFormatter.string(from: now)
        let version = getNextSessionNumber()
        return "Session_\(datePart)_\(timePart)_v\(version)"
    }

    // MARK: - Private helpers

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func documentURL(for fileName: String) -> URL {
        Self.documentsDirectory.appendingPathComponent(fileName)
    }

    /// Appends a single line to the named CSV file using a file handle so
    /// that existing content is preserved.
    private func appendToCSV(_ line: String, fileName: String) {
        let fileURL = documentURL(for: fileName)
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            // File doesn't exist yet — create it.
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Formats elapsed seconds as `MM:SS.d` (truncated, not rounded).
    private func formatTrialTime(_ elapsed: TimeInterval) -> String {
        let totalDeciseconds = Int(elapsed * 10) // truncate, don't round
        let deciseconds = totalDeciseconds % 10
        let totalSeconds = totalDeciseconds / 10
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d.%d", minutes, seconds, deciseconds)
    }

    /// Scans existing CSV files for the highest `_vN` suffix and returns
    /// `N + 1`.
    private static func getNextSessionNumber() -> Int {
        let documentsURL = documentsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return 1
        }

        let pattern = try! NSRegularExpression(pattern: #"_v(\d+)\.csv$"#)
        var maxVersion = 0

        for url in contents where url.pathExtension == "csv" {
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if let match = pattern.firstMatch(in: name, range: range),
               let versionRange = Range(match.range(at: 1), in: name),
               let version = Int(name[versionRange]) {
                maxVersion = max(maxVersion, version)
            }
        }

        return maxVersion + 1
    }
}
