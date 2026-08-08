//
//  IntersectionDetailScreen.swift
//  TactileNav
//
//  One junction, opened by double-tapping its red box on the street map.
//
//  Everything on it is the real geometry of that junction — the arms at their true bearings,
//  and the sidewalks and crossings OpenStreetMap records at that corner. See
//  `IntersectionScene`.
//
//  Two ways back, and no others: a double tap anywhere, and a three-finger swipe right (plus
//  VoiceOver's own escape and scroll, which are the same two gestures under VoiceOver). There
//  is no navigation-bar back button and no one-finger swipe — one finger is exploration on this
//  screen, and every accidental pop while reading the junction came from that.
//

import SwiftUI
import UIKit

struct IntersectionDetailScreen: View {

    let junction: Intersection
    let map: StreetMap

    @Environment(\.dismiss) private var dismiss
    @State private var hasAnnounced = false
    /// Set the moment we start leaving, so a delayed announcement does not land on the map.
    @State private var hasLeft = false

    var body: some View {
        // The junction, and nothing else. Everything that was written underneath — the name,
        // the arms, the gesture hints — is said on arrival instead, so the drawing gets the
        // whole screen and there is nothing to read past to reach it.
        IntersectionTactileView(junction: junction, map: map, onDoubleTap: goBack)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.separator)))
            .padding(.horizontal)
            .padding(.bottom, 12)
        .navigationTitle("Intersection")
        .navigationBarTitleDisplayMode(.inline)
        // No back button: back is the double tap and the three-finger swipe, nothing else.
        .navigationBarBackButtonHidden(true)
        // And no one-finger swipe-back either — one finger is exploration here.
        .disablesSwipeBack()
        .background(BackGestures(onBack: goBack))
        .accessibilityAction(.escape) { goBack() }
        .onAppear(perform: announceOnce)
        .onDisappear(perform: silence)
    }

    private func announceOnce() {
        guard !hasAnnounced else { return }
        hasAnnounced = true
        // Delayed past the push. iOS drops screen-change posts made during a transition, which
        // is how an entry announcement ends up never happening at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Only if we are still here. A quick double tap straight back out would otherwise
            // fire this announcement over the map we have already returned to.
            guard !hasLeft else { return }
            let text = IntersectionScene.entryAnnouncement(for: junction)
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .screenChanged, argument: text)
            } else {
                StreetFeedbackController.shared.announceImmediately(text)
            }
        }
    }

    /// Everything this screen can be making a noise with, stopped.
    ///
    /// Both controllers, because the close-up speaks through its own and the entry
    /// announcement goes through the map's. Missing either one leaves speech running on over
    /// the screen underneath.
    private func silence() {
        hasLeft = true
        IntersectionFeedbackController.shared.stopAll()
        StreetFeedbackController.shared.silence()
    }

    private func goBack() {
        silence()
        dismiss()
    }
}

// MARK: - Back gestures

/// Three-finger swipe right, and VoiceOver's three-finger scroll, both meaning "back".
///
/// A zero-size UIKit view rather than SwiftUI gestures: a three-finger swipe has no SwiftUI
/// equivalent, and VoiceOver delivers its scroll as `accessibilityScroll` on a UIView.
private struct BackGestures: UIViewRepresentable {
    let onBack: () -> Void

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.onBack = onBack
        return view
    }

    func updateUIView(_ view: HostView, context: Context) { view.onBack = onBack }

    final class HostView: UIView {
        var onBack: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = false

            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(back))
            swipe.numberOfTouchesRequired = 3
            swipe.direction = .right
            addGestureRecognizer(swipe)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        @objc private func back() { onBack?() }

        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            guard direction == .right else { return false }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
            UIAccessibility.post(notification: .announcement, argument: "Going back")
            onBack?()
            return true
        }
    }
}
