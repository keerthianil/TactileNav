//
//  ExplorerMapScreen.swift
//  TactileNav
//
//  The map, opened at the place you asked for.
//
//  The same tactile engine as Congress Square and deliberately the same gestures — one finger
//  explores, two pan, three go back — because a second map that behaved differently would be a
//  second thing to learn rather than the same map somewhere else.
//
//  What is added is the answer to the question: an amber dot where the search sent you, with its
//  own fast-pulse haptic, and a Recenter that comes back to *it* rather than to a fixed point
//  across town.
//

import SwiftUI
import UIKit

struct ExplorerMapScreen: View {

    let map: StreetMap
    let place: SearchResult
    /// Clears the binding that pushed this screen. Same single-writer rule as the junction
    /// close-up — see `IntersectionDetailScreen.onLeave`.
    let onLeave: () -> Void

    @State private var commands = StreetMapCommands()
    @State private var openJunction: OpenJunction?

    private struct OpenJunction: Identifiable, Hashable {
        let id: String
        let junction: Intersection
        let map: StreetMap

        static func == (a: OpenJunction, b: OpenJunction) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        PortlandMapView(
            map: map,
            name: "\(place.name) map",
            introduction: introduction,
            commands: commands,
            onBackGesture: goBack,
            onIntersectionDoubleTap: { junction in
                guard openJunction == nil else { return }
                openJunction = OpenJunction(id: junction.id, junction: junction, map: map)
            },
            locator: MapLocator(position: place.position, name: place.name),
            homeCenter: place.position,
            homeName: place.name
        )
        .ignoresSafeArea(edges: .bottom)
        .navigationDestination(item: $openJunction) { selection in
            IntersectionDetailScreen(junction: selection.junction, map: selection.map,
                                     onLeave: { openJunction = nil })
        }
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    commands.recenter?()
                } label: {
                    Label("Back to the result", systemImage: "scope")
                }
                .accessibilityLabel("Back to \(place.name)")
                .accessibilityHint("Returns the map to the place you searched for")
            }
        }
        .onDisappear {
            // Not while a junction is open: pushing the close-up takes this screen off screen
            // too, and both share one speech channel.
            guard openJunction == nil else { return }
            StreetFeedbackController.shared.silence()
        }
    }

    /// Said once on arrival, in the app's own voice, after VoiceOver has read the map's name.
    /// North is stated outright because nothing else on the screen says which way is up, and
    /// every direction the map gives afterwards depends on knowing it.
    private var introduction: String {
        "\(place.name). \(place.detail). Tactile street map, north up. "
        + "Drag one finger to explore, two fingers to pan. "
        + "The searched place is marked with a dot."
    }

    private func goBack() {
        StreetFeedbackController.shared.silence()
        onLeave()
    }
}
