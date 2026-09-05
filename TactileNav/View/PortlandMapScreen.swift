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

    /// Builds the study route against the loaded map, or `nil` for the plain Congress Square
    /// screen. A function rather than a stored `RouteScene?`, because the route cannot be built
    /// until the map has finished loading — see `load()`.
    var routeBuilder: ((StreetMap) -> RouteScene?)?
    var title = "Congress Square"

    private enum LoadPhase {
        case loading
        case ready(map: StreetMap, route: RouteScene?)
        case failed
    }

    @State private var phase: LoadPhase = .loading
    @State private var hasAppeared = false
    @State private var commands = StreetMapCommands()
    /// The junction a double tap opened, if any.
    @State private var openJunction: OpenJunction?

    /// Identifiable wrapper so `navigationDestination(item:)` can drive the push.
    ///
    /// It carries the junction and the map outright rather than an id to look them up by.
    /// A lookup can miss, and a destination builder that produces nothing is how SwiftUI is
    /// told to empty the navigation stack — which lands the user on the home screen. Carrying
    /// the values makes the destination total: whatever is in the binding, there is a screen
    /// for it. Both are value types over copy-on-write storage, so this costs nothing.
    private struct OpenJunction: Identifiable, Hashable {
        let id: String
        let junction: Intersection
        let map: StreetMap
        let route: RouteScene?

        static func == (a: OpenJunction, b: OpenJunction) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        content
            // Attached here, unconditionally, and never inside the `switch` in `content`.
            //
            // A `navigationDestination` registered inside a conditional branch is only
            // registered while that branch happens to be in the tree. Popping back re-evaluates
            // the branch, SwiftUI finds no destination for the binding it is still holding, and
            // resolves that by emptying the stack — which is why opening a junction a second
            // time threw the user out to the home screen.
            //
            // The builder is unconditional for the same reason: see `OpenJunction`.
            .navigationDestination(item: $openJunction) { selection in
                IntersectionDetailScreen(junction: selection.junction, map: selection.map,
                                         route: selection.route,
                                         onLeave: { openJunction = nil })
            }
            .navigationTitle(title)
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
            .onDisappear {
                // Not while a junction is open. Pushing the close-up takes this screen off
                // screen too, and the two now share one speech channel — so silencing here
                // unconditionally cut the junction's own introduction off before it started.
                guard openJunction == nil else { return }
                StreetFeedbackController.shared.silence()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Loading map")
                .accessibilityLabel("Loading the Congress Square map")

        case .ready(let map, let route):
            PortlandMapView(map: map,
                            route: route,
                            name: Self.mapName,
                            introduction: Self.introduction(streetCount: map.features.count,
                                                            routeGiven: route != nil),
                            commands: commands,
                            onBackGesture: { dismiss() },
                            onIntersectionDoubleTap: { junction in
                                // Ignored while one is already open. A double tap that lands
                                // during the pop animation used to set the binding while
                                // SwiftUI was still clearing it, and the write that arrived
                                // second emptied the stack out to the home screen.
                                guard openJunction == nil else { return }
                                openJunction = OpenJunction(id: junction.id,
                                                            junction: junction, map: map,
                                                            route: route)
                            })
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
        let routeBuilder = routeBuilder
        Task.detached(priority: .userInitiated) {
            let result = try? PortlandMapLoader.loadStreetMap(context: context)
            await MainActor.run {
                guard let result else {
                    phase = .failed
                    return
                }
                // Built alongside the map rather than lazily on first touch: a route that fails
                // to resolve should show as a plain map immediately, not partway through a
                // participant's first exploration.
                phase = .ready(map: result, route: routeBuilder?(result))
                // The map introduces itself once it is on screen and laid out, in one place
                // for both VoiceOver states — see `PortlandMapView.Coordinator.announceArrival`.
            }
        }
    }

    /// What VoiceOver reads when focus lands on the map. A name, not a description: anything
    /// longer is still being read when a finger starts exploring, and the two talk over each
    /// other. See `PortlandStreetScrollView.mapName`.
    static let mapName = "Congress Square street map"

    /// The rest of it, said in the app's own voice once VoiceOver has finished with the name,
    /// and dropped the moment a finger arrives.
    static func introduction(streetCount: Int, routeGiven: Bool = false) -> String {
        var text = "Congress Square, downtown Portland. \(streetCount) streets. "
        + "Drag one finger to explore, two fingers to pan. "
        + "Double tap an intersection to open it."
        if routeGiven {
            text += " A route is marked. Follow it by feel: it pulses, where a plain street buzzes."
        }
        return text
    }
}
