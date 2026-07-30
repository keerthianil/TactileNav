//
//  PortlandMapScreen.swift
//  TactileNav
//
//  The Congress Square screen: a pannable street-only tactile map of downtown Portland.
//
//  Loading happens off the main thread — the extract is ~2,000 elements, and projecting it
//  and building the spatial index would drop frames on the way in. All feedback stops when
//  the screen goes away.
//

import SwiftUI

struct PortlandMapScreen: View {

    @Environment(\.dismiss) private var dismiss

    private enum LoadPhase {
        case loading
        case ready(StreetMap)
        case failed
    }

    @State private var phase: LoadPhase = .loading
    @State private var hasAppeared = false

    var body: some View {
        content
            .navigationTitle("Congress Square")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                load()
            }
            .onDisappear { StreetFeedbackController.shared.stopAll() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Loading map")
                .accessibilityLabel("Loading the Congress Square map")

        case .ready(let map):
            PortlandMapView(map: map, onBackGesture: { dismiss() })
                .ignoresSafeArea(edges: .bottom)

        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text("The Congress Square map could not be loaded.")
                    .multilineTextAlignment(.center)
            }
            .padding()
            .accessibilityElement(children: .combine)
        }
    }

    private func load() {
        // Read the device metrics and label font here, on the main actor, then project the
        // ~2,000-element extract off it.
        let context = PortlandMapLoader.LoadContext.current()
        Task.detached(priority: .userInitiated) {
            let result = try? PortlandMapLoader.loadStreetMap(context: context)
            await MainActor.run {
                guard let result else {
                    phase = .failed
                    return
                }
                phase = .ready(result)
                announceEntry(featureCount: result.features.count)
            }
        }
    }

    private func announceEntry(featureCount: Int) {
        StreetFeedbackController.shared.announceScreenEntry(
            "Congress Square, downtown Portland. A street map of \(featureCount) streets, "
            + "sidewalks and crossings. Drag one finger to explore, two fingers to pan the map.")
    }
}
