//
//  RTMRouxMapView.swift
//  TactileNav  (RouxTactileMap)
//
//  THIS FILE IS
//  This is the whole screen you land on from the "Map" list. Its job is small:
//    1. Load the bundled map data file `roux_portland.json`.
//    2. Convert it into our simple models (streets / intersections / places) using
//       RTMDocumentAdapter.
//    3. Show the actual map (RTMLiveMapView) plus a few floating buttons.
//
//  We track a `phase` so the screen can show three different things: a spinner while
//  loading, the map once it's ready, or an error message if the file is missing.
//
//  ACCESSIBILITY: the floating buttons (zoom in, zoom out, re-center) are the easy
//  way for a blind / VoiceOver user to control the map — VoiceOver can read and tap
//  buttons normally, whereas pinching to zoom is hard without sight.
//
//  Note: exploration uses a simulated dot (not real GPS), so this screen needs no
//  location permission.
//

import SwiftUI
import UIKit
import TactileMapCore

struct RTMRouxMapView: View {

    // The three things the screen can be showing at any moment.
    private enum Phase {
        case loading
        case loaded(streets: [RTMDiscoveredStreet], intersections: [RTMDiscoveredIntersection], pois: [RTMDiscoveredPOI])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    // The "to-do note" we hand the map (zoom in, re-center, etc). See RTMMapCommand.
    @State private var command: RTMMapCommand = .none
    // The map writes its current zoom distance here; we don't show it, but the map
    // needs somewhere to report it.
    @State private var zoom: Double = 0

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Loading map…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded(let streets, let intersections, let pois):
                mapContent(streets: streets, intersections: intersections, pois: pois)

            case .failed(let message):
                errorView(message)
            }
        }
        .navigationTitle("Roux Institute Map")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }   // runs once when the screen appears
    }

    // MARK: - The map + its floating buttons

    private func mapContent(
        streets: [RTMDiscoveredStreet],
        intersections: [RTMDiscoveredIntersection],
        pois: [RTMDiscoveredPOI]
    ) -> some View {
        // ZStack = layers stacked on top of each other. The map fills the screen and
        // the buttons float in the bottom-right corner.
        ZStack(alignment: .bottomTrailing) {
            RTMLiveMapView(
                streets: streets,
                intersections: intersections,
                pois: pois,
                command: $command,
                debugZoom: $zoom
            )
            .ignoresSafeArea()

            controls
                .padding(.trailing, 16)
                .padding(.bottom, 32)
        }
        // Stop the swipe-from-edge "back" so swiping to move the map can't pop
        // the screen. Back stays on the nav-bar button and VoiceOver Z-scrub.
        .background(BackSwipeDisabler())
    }

    /// The stack of round buttons. Each one just sets `command`; the map reacts.
    /// Order top→bottom: zoom in (+), zoom out (−), re-center on the dot.
    private var controls: some View {
        VStack(spacing: 12) {
            controlButton(
                systemImage: "plus",
                label: "Zoom in",
                hint: "Moves one zoom level closer."
            ) { command = .zoomIn }

            controlButton(
                systemImage: "minus",
                label: "Zoom out",
                hint: "Moves one zoom level farther away."
            ) { command = .zoomOut }

            optionsMenu
        }
    }

    /// A tappable "Options" menu — the VoiceOver-friendly replacement for the
    /// rotor (which Direct Touch makes unavailable on the map). VoiceOver reads
    /// each item; double-tap to pick. New functions can be added here later.
    private var optionsMenu: some View {
        Menu {
            Button {
                command = .centerOnUser
            } label: {
                Label("Center on my location", systemImage: "location.fill")
            }
            Button {
                command = .fitFeatures
            } label: {
                Label("Fit whole area", systemImage: "map")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title2.weight(.semibold))
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("More options")
        .accessibilityHint("Center on your location, or fit the whole area.")
    }

    /// Makes one round, VoiceOver-labeled button. We reuse this for every control so
    /// they all look and behave the same.
    private func controlButton(
        systemImage: String,
        label: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .frame(width: 48, height: 48)            // big enough to tap easily
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel(label)   // what VoiceOver reads
        .accessibilityHint(hint)     // the longer explanation VoiceOver reads after
        .accessibilityAddTraits(.isButton)
    }

    /// Shown if the map data file couldn't be loaded.
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Couldn't load the map")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Loading the map data

    @MainActor
    private func load() async {
        // Parsing + projecting the JSON can take a moment, so we do it on a
        // background task (Task.detached) and only bring the finished result back to
        // the main thread to show it. This keeps the UI from freezing.
        let result = await Task.detached(priority: .userInitiated) { () -> RTMDocumentAdapter.Result? in
            guard let document = try? TactileMapDocument.load(from: "roux_portland") else { return nil }
            return RTMDocumentAdapter.convert(document)
        }.value

        // If the file was missing or had nothing in it, show the error screen.
        guard let result, !(result.streets.isEmpty && result.intersections.isEmpty && result.pois.isEmpty) else {
            phase = .failed("Map data 'roux_portland.json' wasn't found or was empty.")
            return
        }

        phase = .loaded(streets: result.streets, intersections: result.intersections, pois: result.pois)

        // Tell VoiceOver users what just appeared and how to use it.
        UIAccessibility.post(
            notification: .screenChanged,
            argument: "Roux Institute map. \(result.streets.count) streets, \(result.pois.count) places. Drag one finger to explore streets and places. Use the zoom and Options buttons to change the view."
        )
    }
}

/// Disables the swipe-from-left-edge "back" gesture while this screen is shown,
/// so swiping to move the map can't accidentally pop back. Back is still
/// available via the navigation-bar button and the VoiceOver Z-scrub. The
/// gesture is re-enabled when the screen leaves.
private struct BackSwipeDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        }
        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            if parent == nil {
                navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            }
        }
    }
}
