// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TactileMapKit",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        // Full package — most teams will import this
        .library(
            name: "TactileMapKit",
            targets: ["TactileMapCore", "TactileMapFeedback", "TactileMapView", "TactileMapLogging"]
        ),
        // Individual modules for teams that only need part of the stack
        .library(name: "TactileMapCore", targets: ["TactileMapCore"]),
        .library(name: "TactileMapFeedback", targets: ["TactileMapFeedback"]),
        .library(name: "TactileMapView", targets: ["TactileMapView"]),
        .library(name: "TactileMapLogging", targets: ["TactileMapLogging"]),
    ],
    targets: [
        // MARK: - Core: Data models, JSON parsing, coordinate math, device PPI
        // Zero UIKit dependency — Foundation + CoreLocation + CoreGraphics only
        .target(
            name: "TactileMapCore",
            dependencies: []
        ),

        // MARK: - Feedback: Haptic engine, spatial audio, speech synthesis
        // Depends on Core for element types and properties
        .target(
            name: "TactileMapFeedback",
            dependencies: ["TactileMapCore"]
        ),

        // MARK: - View: MapKit rendering, gestures, hit detection, VoiceOver
        // Depends on Core (models) and Feedback (policies)
        .target(
            name: "TactileMapView",
            dependencies: ["TactileMapCore", "TactileMapFeedback"]
        ),

        // MARK: - Logging: Touch event logging, CSV export, file management UI
        // Depends on Core for event types
        .target(
            name: "TactileMapLogging",
            dependencies: ["TactileMapCore"]
        ),

        // MARK: - Tests
        .testTarget(
            name: "TactileMapCoreTests",
            dependencies: ["TactileMapCore"],
            resources: [.copy("TestResources")]
        ),
        .testTarget(
            name: "TactileMapFeedbackTests",
            dependencies: ["TactileMapFeedback"]
        ),
        .testTarget(
            name: "TactileMapViewTests",
            dependencies: ["TactileMapView"]
        ),
    ]
)
