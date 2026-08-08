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
//  Ways back, matching the street map so the two screens behave the same: the Back button, a
//  three-finger swipe right, a double tap anywhere on the diagram, and VoiceOver's escape.
//  A one-finger swipe is exploration here as well and never navigates.
//

import SwiftUI
import UIKit

struct IntersectionDetailScreen: View {

    let junction: Intersection
    let map: StreetMap

    @Environment(\.dismiss) private var dismiss
    @State private var hasAnnounced = false

    var body: some View {
        VStack(spacing: 12) {
            // Double tap anywhere on the diagram also goes back, as it does in the
            // reference app — the gesture that opened this screen closes it.
            IntersectionTactileView(junction: junction, map: map, onDoubleTap: goBack)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.separator)))

            armsSummary
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
        .navigationTitle("Intersection")
        .navigationBarTitleDisplayMode(.inline)
        // A one-finger drag is exploration on this screen too.
        .disablesSwipeBack()
        .background(BackGestures(onBack: goBack))
        .accessibilityAction(.escape) { goBack() }
        .onAppear(perform: announceOnce)
        .onDisappear { StreetFeedbackController.shared.stopAll() }
    }

    /// The arms in writing, for anyone reading the screen rather than feeling it. Also the
    /// thing a sighted researcher checks the geometry against.
    private var armsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(junction.announcement)
                .font(.headline)
            ForEach(Array(junction.legs.enumerated()), id: \.offset) { _, arm in
                Text("\(arm.streetName) — \(arm.compassLabel)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Text("Drag one finger to explore. Double tap or swipe three fingers right to go back. "
                 + "Works with VoiceOver on or off.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        // Read as one block: the arms are a list of facts about one place, and swiping through
        // them one line at a time is slower than hearing the sentence.
        .accessibilityElement(children: .combine)
    }

    private func announceOnce() {
        guard !hasAnnounced else { return }
        hasAnnounced = true
        // Delayed past the push. iOS drops screen-change posts made during a transition, which
        // is how an entry announcement ends up never happening at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let text = IntersectionScene.entryAnnouncement(for: junction)
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .screenChanged, argument: text)
            } else {
                StreetFeedbackController.shared.announceImmediately(text)
            }
        }
    }

    private func goBack() {
        StreetFeedbackController.shared.stopAll()
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
