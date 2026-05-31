import Foundation
import TactileMapCore

// MARK: - Touch Event Type

/// Classifies each phase of a touch interaction.
public enum TouchEventType: String, Sendable, Codable {
    case touchDown = "Touch Down"
    case touchMove = "Touch Move"
    case touchUp = "Touch Up"
}

// MARK: - Touch Event

/// A single touch event captured during an exploration session.
public struct TouchEvent: Sendable {

    /// Wall-clock timestamp of the event.
    public let timestamp: Date

    /// Seconds elapsed since the session started.
    public let sessionElapsed: TimeInterval

    /// Phase of the touch (down, move, up).
    public let eventType: TouchEventType

    /// Display name of the element under the touch, or a description
    /// such as "Background" when no element is hit.
    public let elementName: String

    /// The semantic type of the element, if any.
    public let elementType: TactileElementType?

    /// Touch location in the coordinate space of the hosting view.
    public let touchPoint: CGPoint

    /// Arbitrary key-value pairs that should appear as additional CSV columns.
    public let custom: [String: String]

    public init(
        timestamp: Date,
        sessionElapsed: TimeInterval,
        eventType: TouchEventType,
        elementName: String,
        elementType: TactileElementType?,
        touchPoint: CGPoint,
        custom: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.sessionElapsed = sessionElapsed
        self.eventType = eventType
        self.elementName = elementName
        self.elementType = elementType
        self.touchPoint = touchPoint
        self.custom = custom
    }
}
