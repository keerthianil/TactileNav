//
//  PortlandMapScreen.swift
//  TactileNav
//
//  Level-1 screen: the Congress Square tactile map plus a time-of-day traffic selector
//  (peak / normal / light). Double-tapping an intersection presents the Level-2 crossing
//  simulation. All feedback stops on disappear.
//

import SwiftUI

struct PortlandMapScreen: View {

    @Environment(\.dismiss) private var dismiss
    @State private var trafficState: TrafficState = .normal
    @State private var corridors: [PortlandCorridor] = []
    @State private var features: [PortlandMapFeature] = []
    @State private var apsLocations: [PortlandAPS] = []
    @State private var trafficSegments: [PortlandTrafficSegment] = []
    @State private var trafficIntersections: [PortlandTrafficIntersection] = []
    @State private var selectedIntersection: PortlandIntersection?
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            PortlandMapView(
                features: features,
                onDoubleTapIntersection: { selectedIntersection = $0 },
                onBackGesture: { dismiss() },
                trafficSegments: trafficSegments,
                trafficIntersections: trafficIntersections,
                apsLocations: apsLocations,
                trafficState: trafficState,
                onTrafficStateChange: { trafficState = $0 },
                level: 1
            )
            .ignoresSafeArea(edges: .top)

            trafficSelector
        }
        .navigationTitle("Congress Square")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedIntersection) { intersection in
            PortlandIntersectionDetailView(
                intersection: intersection,
                allCorridors: corridors,
                trafficSegments: trafficSegments,
                apsLocations: apsLocations,
                trafficState: trafficState
            )
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            loadData()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                PortlandFeedbackManager.shared.speak(
                    "Congress Square, downtown Portland. Drag to explore streets and intersections. Double tap an intersection for its crossing detail.")
            }
        }
        .onDisappear { PortlandFeedbackManager.shared.stopAllFeedback() }
    }

    private var trafficSelector: some View {
        VStack(spacing: 8) {
            Picker("Traffic time of day", selection: $trafficState) {
                ForEach(TrafficState.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .accessibilityLabel("Traffic time of day")
            .accessibilityHint("Changes traffic density: felt as vibration strength and heard as road rumble while exploring")

            Text(trafficState.description)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityLabel("\(trafficState.label). \(trafficState.description)")
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private func loadData() {
        let map = PortlandMapLoader.loadLevel1()
        corridors = map.corridors
        features = map.all
        apsLocations = PortlandMapLoader.loadAPS()
        let traffic = PortlandMapLoader.loadTraffic()
        trafficSegments = traffic.segments
        trafficIntersections = traffic.intersections
    }
}
