import Foundation
import os

/// Lightweight, opt-in diagnostic logging for the framework.
///
/// Diagnostics are **off by default** so the console stays quiet in normal
/// use.  Turn them on while troubleshooting to surface engine failures,
/// coordinate conversions, and device-detection details:
///
/// ```swift
/// TactileMapDiagnostics.isEnabled = true
/// ```
///
/// Output goes through the unified logging system under the
/// `com.tactilemapkit` subsystem, so it is also visible in Console.app and
/// `log stream`.
public enum TactileMapDiagnostics {

    /// Master switch.  When `false` (the default) no diagnostic messages are
    /// emitted, keeping the console clear for consuming apps.
    public static var isEnabled = false

    private static let osLog = OSLog(subsystem: "com.tactilemapkit", category: "diagnostics")

    /// Emit a diagnostic message when diagnostics are enabled.
    ///
    /// - Parameter message: An autoclosure so the string is only built when
    ///   diagnostics are actually enabled.
    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        os_log("%{public}@", log: osLog, type: .debug, message())
    }
}
