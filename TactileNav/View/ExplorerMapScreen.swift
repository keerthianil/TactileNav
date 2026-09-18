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
    let configuration: MapConfiguration
    private var place: GeocodedPlace { configuration.place }

    /// Where the searched place ended up on this map.
    ///
    /// `StreetMap.build` was handed the searched point and snapped it to the nearest junction
    /// within eighty metres, which is a better place to land a first finger than a spot
    /// mid-block — so the dot goes where the map actually opened, not where the geocoder
    /// pointed.
    private var locatorPosition: CGPoint { map.initialCenter }
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
            locator: MapLocator(position: locatorPosition, name: place.name),
            homeCenter: locatorPosition,
            homeName: place.name,
            showsOrientation: true,
            distanceUnit: configuration.units,
            // The rotor's copy of the north arrow and the scale bar.
            //
            // Those two are drawn in the corners for anyone who can see them, and a reader who
            // cannot has exactly the same right to know which way the map is turned and how much
            // ground is on it. It is an action rather than part of the map's label because it is
            // a thing you ask for when you have lost your bearings, not something to hear every
            // time focus lands on the map.
            extraActions: [("Map details", speakDetails)]
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
        configuration.arrivalSummary
        + " Drag one finger to explore, two fingers to pan. "
        + "The place you searched for is marked with a dot."
    }

    /// Everything about this map that a finger cannot discover by touching it.
    private func speakDetails() {
        let scale = configuration.scale
        StreetFeedbackController.shared.announceImmediately(
            "\(place.name). North is up. "
            + "Scale \(scale.label), about \(configuration.units.spell(groundAcross)) across the screen. "
            + "Showing \(configuration.features.spoken).")
    }

    /// How much ground the screen holds at this scale, in metres.
    private var groundAcross: CGFloat {
        UIScreen.main.bounds.width / map.metrics.pointsPerMeter
    }

    private func goBack() {
        StreetFeedbackController.shared.silence()
        onLeave()
    }
}
