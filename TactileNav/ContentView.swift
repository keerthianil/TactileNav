import SwiftUI
import TactileMapFeedback
import TactileMapLogging

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Landmark Study") {
                    NavigationLink("Practice Map",
                                   destination: LandmarkStudyView(condition: .practiceNL))
                }

                Section("OpenStreetMap") {
                    NavigationLink("Roux Map (stage zoom)",
                                   destination: RouxStageMapView())
                }

                Section("Custom Maps") {
                    NavigationLink("Branch Road Demo",
                                   destination: BranchMapView())
                }

                Section("Tools") {
                    NavigationLink("Feedback Customization Tester",
                                   destination: FeedbackCustomizationTesterView())
                    NavigationLink("Files",
                                   destination: FilesListView())
                }
            }
            .navigationTitle("TactileNav")
        }
    }
}

// MARK: - Branch Road Demo

private struct BranchMapView: View {
    @StateObject private var vm = MapViewModel(mapFileName: "custom_branch_map")
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GenericMapCanvasView(document: vm.document, policy: vm.policy)
            .ignoresSafeArea()
            .navigationTitle("Branch Road Demo")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                vm.policy.stopAll()
                vm.logger.endSession()
            }
    }
}

#Preview {
    ContentView()
}
