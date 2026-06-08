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
//  Note: exploration uses the finger as the cursor (not real GPS), so this screen
//  needs no location permission.
//

import SwiftUI
import UIKit
import CoreLocation
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
    @State private var currentZoomLevel: RTMFunctionalZoomLevel = .streets

    // Rotor-style cursor: each "Next point of interest" tap advances through the
    // list and jumps the camera there (wraps around).
    @State private var poiCursor = -1

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
        .toolbarBackground(.hidden, for: .navigationBar)
        .background(BackSwipeDisabler())
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
                debugZoom: $zoom,
                currentZoomLevel: $currentZoomLevel
            )
            .ignoresSafeArea()

            controls(pois: pois)
                .padding(.trailing, 16)
                .padding(.bottom, 32)
        }
    }

    /// The stack of round buttons. Each one just sets `command`; the map reacts.
    /// Order top→bottom: zoom in (+), zoom out (−), re-center on the dot.
    private func controls(pois: [RTMDiscoveredPOI]) -> some View {
        VStack(spacing: 12) {
            controlButton(
                systemImage: "plus",
                label: "Zoom in",
                hint: "Currently \(currentZoomLevel.voiceOverLabel). Moves one level closer to detail. Or triple tap the map to cycle zoom."
            ) { sendCommand(.zoomIn) }

            controlButton(
                systemImage: "minus",
                label: "Zoom out",
                hint: "Currently \(currentZoomLevel.voiceOverLabel). Moves one level toward overview. Or triple tap the map to cycle zoom."
            ) { sendCommand(.zoomOut) }

            optionsMenu(pois: pois)
        }
    }

    /// A tappable "Options" menu — the VoiceOver-friendly way to navigate without
    /// dragging. Pick a point of interest and the camera jumps there and announces
    /// it (like choosing from a rotor). Also page turn, center, and fit.
    private func optionsMenu(pois: [RTMDiscoveredPOI]) -> some View {
        Menu {
            if currentZoomLevel.showPOIs, !pois.isEmpty {
                Button {
                    poiCursor = (poiCursor + 1) % pois.count
                    let p = pois[poiCursor]
                    sendCommand(.moveTo(lat: p.coordinate.latitude, lon: p.coordinate.longitude))
                } label: {
                    Label("Next point of interest", systemImage: "mappin.and.ellipse")
                }
            }
            Button { sendCommand(.pageTurn(.north)) } label: {
                Label("Go north", systemImage: "arrow.up")
            }
            Button { sendCommand(.pageTurn(.south)) } label: {
                Label("Go south", systemImage: "arrow.down")
            }
            Button { sendCommand(.pageTurn(.east)) } label: {
                Label("Go east", systemImage: "arrow.right")
            }
            Button { sendCommand(.pageTurn(.west)) } label: {
                Label("Go west", systemImage: "arrow.left")
            }
            Button { sendCommand(.goBackPage) } label: {
                Label("Go back", systemImage: "arrow.uturn.backward")
            }
            Button { sendCommand(.centerOnUser) } label: {
                Label("Center map", systemImage: "scope")
            }
            Button { sendCommand(.fitFeatures) } label: {
                Label("Fit whole area", systemImage: "map")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title2.weight(.semibold))
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("Options")
        .accessibilityHint("Step to places, turn the page north south east or west, go back, center, or fit the whole area.")
    }

    /// Resets then sets `command` so repeated taps of the same action always reach the map.
    private func sendCommand(_ newCommand: RTMMapCommand) {
        command = .none
        DispatchQueue.main.async { command = newCommand }
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
            argument: "Roux Institute map. \(result.streets.count) streets, \(result.pois.count) places. Drag one finger to explore. Triple tap to cycle zoom. At the edge, double tap to turn the page. Two-finger double tap to go back."
        )
    }
}

/// Shared orientation mask — AppDelegate reads this for per-screen locking.
enum RTMOrientationLock {
    private static let defaultMask: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
    static var mask: UIInterfaceOrientationMask = defaultMask

    static func lockToPortrait(for view: UIView) {
        mask = .portrait
        if #available(iOS 16.0, *), let windowScene = view.window?.windowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
        UIViewController.attemptRotationToDeviceOrientation()
    }

    static func unlock() {
        mask = defaultMask
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

/// Disables the swipe-from-left-edge "back" gesture while this screen is shown.
/// Uses a hidden UIView (not a separate UIViewController) so `findViewController()`
/// reaches the SwiftUI hosting controller that actually sits in the nav stack.
private struct BackSwipeDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> BlockingView { BlockingView() }

    func updateUIView(_ uiView: BlockingView, context: Context) {
        uiView.applyIfNeeded()
    }

    final class BlockingView: UIView {
        private weak var popGesture: UIGestureRecognizer?
        private var savedEnabled = true
        private weak var savedDelegate: (any UIGestureRecognizerDelegate)?
        private let blocker = PopGestureBlocker()

        override init(frame: CGRect) {
            super.init(frame: .zero)
            isHidden = true
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                applyIfNeeded()
            } else {
                restorePopGesture()
            }
        }

        func applyIfNeeded() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                guard let nav = self.findHostingViewController()?.navigationController,
                      let pop = nav.interactivePopGestureRecognizer else { return }

                if self.popGesture !== pop {
                    self.restorePopGesture()
                    self.popGesture = pop
                    self.savedEnabled = pop.isEnabled
                    self.savedDelegate = pop.delegate
                }

                pop.isEnabled = false
                pop.delegate = self.blocker
                RTMOrientationLock.lockToPortrait(for: self)
            }
        }

        private func restorePopGesture() {
            guard let pop = popGesture else { return }
            pop.isEnabled = savedEnabled
            pop.delegate = savedDelegate
            popGesture = nil
            RTMOrientationLock.unlock()
        }

        deinit { restorePopGesture() }

        private func findHostingViewController() -> UIViewController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let vc = next as? UIViewController { return vc }
                responder = next
            }
            return nil
        }
    }

    final class PopGestureBlocker: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }
    }
}
