//
//  PortlandMapLoader.swift
//  TactileNav
//
//  Loads the Congress Square street map.
//
//  The document is a real OpenStreetMap extract of downtown Portland in local metres,
//  parsed by the shared map package. Decoding ~2,000 elements and building the spatial
//  index takes long enough to drop a frame, so the whole load runs off the main thread and
//  hands back a finished `StreetMap` of value types.
//

import CoreText
import Foundation
import TactileMapCore
import UIKit

/// Fields the app reads from the document's metadata that the shared metadata model does
/// not carry. Decoded in a second pass over the same file; unknown keys are ignored on
/// both sides, so one file serves both.
nonisolated struct StreetMapExtras: Decodable {
    struct Point: Decodable {
        let x: Double
        let y: Double

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            x = try container.decode(Double.self)
            y = try container.decode(Double.self)
        }
    }

    struct BoundingBox: Decodable {
        let south: Double
        let west: Double
        let north: Double
        let east: Double
    }

    let initialCenter: Point?
    let bbox: BoundingBox?
    let source: String?

    private enum CodingKeys: String, CodingKey {
        case initialCenter = "initial_center"
        case bbox
        case source
    }

    private struct Envelope: Decodable {
        let metadata: StreetMapExtras?
    }

    static func load(resource: String, bundle: Bundle = .main) -> StreetMapExtras? {
        guard let url = bundle.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data).metadata
    }
}

nonisolated enum PortlandMapLoader {

    static let resourceName = "congress_square"

    enum LoadError: Error {
        case missingDocument
    }

    /// Everything the background load needs that has to be read on the main actor first:
    /// the device's physical metrics and the label font.
    ///
    /// `@unchecked` only because Core Text predates `Sendable`: a `CTFont` is an immutable
    /// Core Foundation value and is safe to read from any thread.
    struct LoadContext: @unchecked Sendable {
        let metrics: StreetMapSizing.Metrics
        let labelFont: CTFont

        @MainActor
        static func current() -> LoadContext {
            let font = UIFont.systemFont(ofSize: StreetMapSizing.labelFontSize, weight: .medium)
            return LoadContext(
                metrics: StreetMapSizing.currentMetrics(),
                labelFont: CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
            )
        }
    }

    /// Loads and projects the street map. Safe to call off the main thread — the context
    /// carries the only two things that had to be read on the main actor.
    static func loadStreetMap(context: LoadContext) throws -> StreetMap {
        guard let document = try? TactileMapDocument.load(from: resourceName, bundle: .main) else {
            throw LoadError.missingDocument
        }
        return StreetMap.build(
            document: document,
            extras: StreetMapExtras.load(resource: resourceName),
            metrics: context.metrics,
            labelFont: context.labelFont
        )
    }
}
