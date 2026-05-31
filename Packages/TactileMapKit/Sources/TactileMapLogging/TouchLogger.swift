import Foundation
import CoreGraphics

// MARK: - Touch Logger Protocol

/// A receiver for touch events during a tactile map exploration session.
///
/// Concrete implementations decide *where* and *how* events are persisted
/// (CSV file, in-memory buffer, remote endpoint, etc.).
@MainActor
public protocol TouchLogger: AnyObject {

    /// Begin a new logging session.
    ///
    /// - Parameter metadata: Arbitrary key-value pairs that describe the
    ///   session (e.g. participant ID, map name, condition).  Implementations
    ///   may use these to generate the output file name or embed them in the
    ///   log header.
    func startSession(metadata: [String: String])

    /// Finalize and close the current session.
    func endSession()

    /// Record a single touch event.
    ///
    /// - Parameter event: The event to log.
    /// - Returns: `true` if the event was actually written (throttling may
    ///   cause move events to be skipped).
    @discardableResult
    func logEvent(_ event: TouchEvent) -> Bool

    /// Whether a session is currently in progress.
    var isSessionActive: Bool { get }
}
