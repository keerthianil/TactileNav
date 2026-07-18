import SwiftUI

struct PortlandIntersectionDetailView: View {

    let intersection: PortlandIntersection
    var trafficSegments: [PortlandTrafficSegment] = []
    var trafficIntersections: [PortlandTrafficIntersection] = []
    var apsLocations: [PortlandAPSLocation] = []
    var selectedTimeOfDay: TrafficTimeOfDay = .midday

    @Environment(\.dismiss) private var dismiss

    @State private var level2Features: [PortlandMapFeature] = []
    @State private var hasAppeared = false

    private var isSignalized: Bool {
        trafficIntersections.contains { $0.id == intersection.featureId && ($0.hasTrafficLight ?? false) }
    }

    private var hasAPS: Bool {
        apsLocations.contains { $0.intersectionId == intersection.featureId }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PortlandMapView(
                features: level2Features,
                isInteractionEnabled: true,
                onDoubleTapIntersection: nil,
                onBackGesture: {
                    PortlandFeedbackManager.shared.stopAllFeedback()
                    dismiss()
                },
                trafficSegments: trafficSegments,
                trafficIntersections: trafficIntersections,
                apsLocations: apsLocations,
                selectedTimeOfDay: selectedTimeOfDay,
                level: 2
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    PortlandFeedbackManager.shared.stopAllFeedback()
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.body.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                }
                .accessibilityLabel("Back to map overview")
                .accessibilityHint("Returns to the full map view")

                if isSignalized {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
                        Text("Traffic Signal")
                            .font(.caption)
                            .fontWeight(.semibold)
                        if hasAPS {
                            Text("APS")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.8))
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(hasAPS
                        ? "Signalized intersection with accessible pedestrian signal"
                        : "Signalized intersection with traffic light")
                }
            }
            .padding(.top, 60)
            .padding(.leading, 16)
        }
        .accessibilityAction(.escape) {
            PortlandFeedbackManager.shared.stopAllFeedback()
            dismiss()
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            loadDetail()
            announceDetail()
        }
        .onDisappear {
            PortlandFeedbackManager.shared.stopAllFeedback()
        }
        .statusBarHidden(true)
    }

    private func loadDetail() {
        level2Features = PortlandMapLoader.loadLevel2Features(for: intersection.featureId)
    }

    private func announceDetail() {
        var announcement = "Intersection detail. \(intersection.featureName). "
        if isSignalized {
            announcement += "Signalized with traffic light. "
        }
        if hasAPS {
            announcement += "Accessible pedestrian signal present. "
        }
        announcement += "Drag to explore roads, sidewalks, and crosswalks. "
        if UIAccessibility.isVoiceOverRunning {
            announcement += "Two finger scrub to go back."
        } else {
            announcement += "Three finger swipe or back button to return."
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            PortlandFeedbackManager.shared.speak(announcement)
        }
    }
}
