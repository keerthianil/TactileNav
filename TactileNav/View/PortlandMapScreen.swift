//
//  PortlandMapScreen.swift
//  TactileNav
//
//  The Congress Square screen: a pannable tactile map of the streets of downtown Portland.
//
//  Loading happens off the main thread — projecting the extract and building the spatial
//  index would drop frames on the way in. All feedback stops when the screen goes away.
//

import SwiftUI
import UIKit

struct PortlandMapScreen: View {

    @Environment(\.dismiss) private var dismiss

    private enum LoadPhase {
        case loading
        case ready(StreetMap)
        case failed
    }

    @State private var phase: LoadPhase = .loading
    @State private var hasAppeared = false
    @State private var commands = StreetMapCommands()
    /// The junction a double tap opened, if any.
    @State private var openJunction: OpenJunction?

    /// Identifiable wrapper so `navigationDestination(item:)` can drive the push.
    private struct OpenJunction: Identifiable, Hashable {
        let id: String
    }

    var body: some View {
        content
            .navigationTitle("Congress Square")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .ready = phase {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            commands.recenter?()
                        } label: {
                            Label("Recenter", systemImage: "scope")
                        }
                        .accessibilityLabel("Recenter on Congress Square")
                        .accessibilityHint("Returns the map to Congress Square if you have panned away")
                    }
                }
            }
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
            PortlandMapView(map: map,
                            description: description(streetCount: map.features.count),
                            commands: commands,
                            onBackGesture: { dismiss() },
                            onIntersectionDoubleTap: { openJunction = OpenJunction(id: $0.id) })
                .ignoresSafeArea(edges: .bottom)
                .navigationDestination(item: $openJunction) { selection in
                    if let junction = map.intersections.first(where: { $0.id == selection.id }) {
                        IntersectionDetailScreen(junction: junction, map: map)
                    }
                }

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
                // With VoiceOver on, the map announces itself once it is on screen and
                // focused — see `announceArrival`. With it off there is nothing to focus, so
                // the same sentence is spoken outright.
                if !UIAccessibility.isVoiceOverRunning {
                    StreetFeedbackController.shared.announceScreenEntry(
                        description(streetCount: result.features.count))
                }
            }
        }
    }

    /// The map's name first, because that is the thing a user needs to hear on arrival and
    /// the thing that was going missing.
    private func description(streetCount: Int) -> String {
        "Congress Square, downtown Portland. A tactile street map of \(streetCount) streets. "
        + "Drag one finger to explore, two fingers to pan. "
        + "Double tap an intersection to open it."
    }
}
