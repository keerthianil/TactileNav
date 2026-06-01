import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Map") {
                    NavigationLink("Roux Institute — Portland (OSM)",
                                   destination: RouxStageMapView())
                }

                Section("Tools") {
                    NavigationLink("Feedback Customization Tester",
                                   destination: FeedbackCustomizationTesterView())
                    NavigationLink("Data Files",
                                   destination: FilesListView())
                }
            }
            .navigationTitle("TactileNav")
        }
    }
}

#Preview {
    ContentView()
}
