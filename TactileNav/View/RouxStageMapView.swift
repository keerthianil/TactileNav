import SwiftUI
import UIKit
import TactileMapCore
import TactileMapFeedback
import TactileMapLogging

// MARK: - Stage levels

/// The user-facing "stage zoom" level — a conceptual navigation-detail level,
/// distinct from any visual/map zoom. Three research-backed levels for now
/// (Palani & Giudice validated 3); can grow to 5 with city-wide data.
enum StageLevel: Int, CaseIterable {
    case neighborhood = 1
    case street       = 2
    case intersection = 3

    var title: String {
        switch self {
        case .neighborhood: return "Neighborhood"
        case .street:       return "Street"
        case .intersection: return "Intersection"
        }
    }
}

// MARK: - Stage filter (information-zoom: reveal more detail per level)

enum StageFilter {

    /// Major road categories shown even at the coarsest level.
    private static let majorRoads: Set<String> = [
        "motorway", "motorway_link", "trunk", "trunk_link",
        "primary", "primary_link", "secondary", "secondary_link",
    ]

    /// Returns a copy of `doc` containing only the features visible at `level`,
    /// reframed so that content fills the screen at every level (the coarse
    /// levels would otherwise look tiny and off-center). This is the
    /// information-zoom: each level reframes to its own content.
    static func filter(_ doc: TactileMapDocument, level: StageLevel) -> TactileMapDocument {
        let shown = doc.features.filter { shouldShow($0, level: level) }
        guard !shown.isEmpty else {
            return TactileMapDocument(version: doc.version, bounds: doc.bounds,
                                      features: shown, metadata: doc.metadata)
        }

        // Bounding box of the visible features.
        var minX =  Double.greatestFiniteMagnitude
        var minY =  Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for f in shown {
            for c in coordinates(of: f) {
                minX = min(minX, c.x); minY = min(minY, c.y)
                maxX = max(maxX, c.x); maxY = max(maxY, c.y)
            }
        }

        let pad = 30.0   // meters of breathing room
        let dx = -minX + pad
        let dy = -minY + pad
        let translated = shown.map { translate($0, dx: dx, dy: dy) }
        let bounds = TactileMapBounds(width: (maxX - minX) + 2 * pad,
                                      height: (maxY - minY) + 2 * pad)
        return TactileMapDocument(version: doc.version, bounds: bounds,
                                  features: translated, metadata: doc.metadata)
    }

    private static func coordinates(of f: MapElement) -> [TactileCoordinate] {
        switch f.geometry {
        case .point(let c):       return [c]
        case .lineString(let cs): return cs
        case .polygon(let cs):    return cs
        }
    }

    private static func translate(_ f: MapElement, dx: Double, dy: Double) -> MapElement {
        let g: TactileGeometry
        switch f.geometry {
        case .point(let c):
            g = .point(TactileCoordinate(x: c.x + dx, y: c.y + dy))
        case .lineString(let cs):
            g = .lineString(cs.map { TactileCoordinate(x: $0.x + dx, y: $0.y + dy) })
        case .polygon(let cs):
            g = .polygon(cs.map { TactileCoordinate(x: $0.x + dx, y: $0.y + dy) })
        }
        return MapElement(id: f.id, elementType: f.elementType, geometry: g, properties: f.properties)
    }

    private static func shouldShow(_ f: MapElement, level: StageLevel) -> Bool {
        let category = f.properties.category ?? ""

        if f.elementType == .corridor {
            // Neighborhood: major roads only. Street/Intersection: all roads.
            return level == .neighborhood ? majorRoads.contains(category) : true
        }

        if f.elementType == .intersection {
            // Junctions appear once you're at street detail or deeper.
            return level != .neighborhood
        }

        if f.elementType == .landmark {
            // Anchor + signals always; crossings only at the deepest level.
            switch level {
            case .neighborhood, .street:
                return category == "anchor" || category == "traffic_signal"
            case .intersection:
                return true
            }
        }

        return true
    }
}

// MARK: - Roux map screen with stage zoom

struct RouxStageMapView: View {
    @StateObject private var vm = MapViewModel(mapFileName: "roux_portland")
    @State private var level: StageLevel = .neighborhood
    @Environment(\.dismiss) private var dismiss

    private var filteredDocument: TactileMapDocument {
        StageFilter.filter(vm.document, level: level)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The map is a VoiceOver direct-interaction region (one-finger
            // raw-touch exploration). No free zoom/pan — the lab's apps use a
            // fixed-scale map, and each stage level reframes to fill the screen.
            // Sizes are in map units = METERS; realistic street widths so the
            // network reads as streets, not blobs. Touch targets stay
            // accessible via the renderer's minHitRadiusPts floor.
            DirectInteractionHost(
                onBackGesture: { dismiss() },
                onZoomIn:  { setLevel(level.rawValue + 1) },
                onZoomOut: { setLevel(level.rawValue - 1) }
            ) {
                GenericMapCanvasView(
                    document: filteredDocument,
                    policy: vm.policy,
                    corridorJSONWidth: 12,
                    landmarkJSONSize: 28,
                    majorJSONRadius: 7,
                    minorJSONRadius: 5
                )
            }
            .ignoresSafeArea()

            levelBar
        }
        .navigationTitle("Roux Map (OSM)")
        .navigationBarTitleDisplayMode(.inline)
        // Magic Tap (two-finger double-tap) jumps straight to detail level.
        .accessibilityAction(.magicTap) {
            setLevel(StageLevel.intersection.rawValue)
        }
        .onDisappear {
            vm.policy.stopAll()
            vm.logger.endSession()
        }
    }

    // Stage-level control. A SEPARATE adjustable accessibility element so it
    // coexists with the map's direct-interaction region: VoiceOver users
    // focus it and swipe up/down to change level. Visible +/- buttons serve
    // sighted / low-vision users and testing.
    private var levelBar: some View {
        HStack {
            Button { setLevel(level.rawValue - 1) } label: {
                Image(systemName: "minus.magnifyingglass").font(.title2)
            }
            .disabled(level == .neighborhood)

            Spacer()
            VStack(spacing: 2) {
                Text("Level \(level.rawValue) / \(StageLevel.allCases.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(level.title).font(.headline)
            }
            Spacer()

            Button { setLevel(level.rawValue + 1) } label: {
                Image(systemName: "plus.magnifyingglass").font(.title2)
            }
            .disabled(level == .intersection)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 24)
        // Expose as a single adjustable control to VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stage zoom level")
        .accessibilityValue("\(level.title), level \(level.rawValue) of \(StageLevel.allCases.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setLevel(level.rawValue + 1)
            case .decrement: setLevel(level.rawValue - 1)
            @unknown default: break
            }
        }
    }

    private func setLevel(_ raw: Int) {
        guard let newLevel = StageLevel(rawValue: raw), newLevel != level else { return }
        level = newLevel
        UIAccessibility.post(notification: .announcement, argument: "\(newLevel.title) level")
    }
}
