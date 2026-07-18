import SwiftUI

struct PortlandIntersectionDetailView: View {

    let intersection: PortlandIntersection
    @Environment(\.dismiss) private var dismiss

    @State private var level2Features: [PortlandMapFeature] = []
    @State private var hasAppeared = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            PortlandMapView(
                features: level2Features,
                isInteractionEnabled: true,
                onDoubleTapIntersection: nil,
                onBackGesture: {
                    dismiss()
                },
                trafficSegments: [],
                apsLocations: [],
                selectedTimeOfDay: .midday,
                level: 2
            )
            .ignoresSafeArea()

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
            .padding(.top, 60)
            .padding(.leading, 16)
            .accessibilityLabel("Back to map overview")
            .accessibilityHint("Returns to the full map view")
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
        .navigationBarHidden(true)
        .statusBarHidden(true)
    }

    private func loadDetail() {
        level2Features = PortlandMapLoader.loadLevel2Features(for: intersection.featureId)
    }

    private func announceDetail() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            PortlandFeedbackManager.shared.speak(
                "Intersection detail. \(intersection.featureName). Drag to explore roads, sidewalks, and crosswalks. Double tap or use back button to return."
            )
        }
    }
}
