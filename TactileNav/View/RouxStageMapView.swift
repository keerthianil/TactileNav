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

    /// Returns a copy of `doc` containing only the features visible at `level`.
    static func filter(_ doc: TactileMapDocument, level: StageLevel) -> TactileMapDocument {
        let features = doc.features.filter { shouldShow($0, level: level) }
        return TactileMapDocument(
            version: doc.version,
            bounds: doc.bounds,
            features: features,
            metadata: doc.metadata
        )
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

    // MARK: Map zoom (visual scale) — distinct from stage zoom (information).
    // Baseline scale is coupled to the stage level; pinch/pan adjust around it.
    @State private var steadyZoom: CGFloat = 1
    @State private var steadyPan: CGSize = .zero
    @State private var zoomAtGestureStart: CGFloat = 1
    @State private var panAtGestureStart: CGSize = .zero

    private var filteredDocument: TactileMapDocument {
        StageFilter.filter(vm.document, level: level)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The map: a VoiceOver direct-interaction region (one-finger
            // raw-touch exploration). Two-finger pinch zooms, two-finger
            // drag pans — driven by the host's UIKit recognizers.
            DirectInteractionHost(
                onBackGesture: { dismiss() },
                onPinch: { scale, state in
                    if state == .began { zoomAtGestureStart = steadyZoom }
                    steadyZoom = min(5, max(1, zoomAtGestureStart * scale))
                },
                onPan: { t, state in
                    if state == .began { panAtGestureStart = steadyPan }
                    steadyPan = CGSize(width: panAtGestureStart.width + t.x,
                                       height: panAtGestureStart.height + t.y)
                }
            ) {
                GenericMapCanvasView(document: filteredDocument, policy: vm.policy)
                    .scaleEffect(steadyZoom, anchor: .center)
                    .offset(steadyPan)
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
        // Couple visual map-zoom baseline to the stage level; recenter.
        steadyZoom = baselineZoom(for: newLevel)
        steadyPan = .zero
        UIAccessibility.post(notification: .announcement, argument: "\(newLevel.title) level")
    }

    private func baselineZoom(for level: StageLevel) -> CGFloat {
        switch level {
        case .neighborhood: return 1.0
        case .street:       return 1.6
        case .intersection: return 2.4
        }
    }
}
