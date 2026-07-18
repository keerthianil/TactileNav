import SwiftUI

struct PortlandMapScreen: View {

    @State private var selectedTimeOfDay: TrafficTimeOfDay = .midday
    @State private var features: [PortlandMapFeature] = []
    @State private var apsLocations: [PortlandAPSLocation] = []
    @State private var trafficSegments: [PortlandTrafficSegment] = []
    @State private var trafficIntersections: [PortlandTrafficIntersection] = []
    @State private var selectedIntersection: PortlandIntersection?
    @State private var showingDetail = false
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            PortlandMapView(
                features: features,
                isInteractionEnabled: true,
                onDoubleTapIntersection: { intersection in
                    selectedIntersection = intersection
                    showingDetail = true
                },
                trafficSegments: trafficSegments,
                apsLocations: apsLocations,
                selectedTimeOfDay: selectedTimeOfDay,
                level: 1
            )
            .ignoresSafeArea(edges: .top)

            trafficTimeSelector
        }
        .navigationTitle("Portland Old Port")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingDetail) {
            if let intersection = selectedIntersection {
                PortlandIntersectionDetailView(intersection: intersection)
            }
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            loadData()
            announceOnAppear()
        }
        .onDisappear {
            PortlandFeedbackManager.shared.stopAllFeedback()
        }
    }

    private var trafficTimeSelector: some View {
        VStack(spacing: 8) {
            Text("Traffic Time of Day")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            Picker("Traffic time of day", selection: $selectedTimeOfDay) {
                ForEach(TrafficTimeOfDay.allCases) { period in
                    Text(period.shortLabel).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .accessibilityLabel("Traffic time of day")
            .accessibilityHint("Changes the traffic density announced when touching a road")

            Text(selectedTimeOfDay.description)
                .font(.caption2)
                .foregroundColor(.secondary)
                .accessibilityLabel(selectedTimeOfDay.label + ". " + selectedTimeOfDay.description)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private func loadData() {
        features = PortlandMapLoader.loadLevel1Features()
        apsLocations = PortlandMapLoader.loadAPSData()

        let trafficData = PortlandMapLoader.loadTrafficData()
        trafficSegments = trafficData.segments
        trafficIntersections = trafficData.intersections
    }

    private func announceOnAppear() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            PortlandFeedbackManager.shared.speak(
                "Portland Old Port map. Drag to explore streets and intersections. Double tap an intersection for detail."
            )
        }
    }
}
