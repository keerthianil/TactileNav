import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Maps") {
                    NavigationLink {
                        PortlandMapScreen()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Congress Square")
                                    .font(.headline)
                                Text("Pannable tactile street map of downtown Portland")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "map.fill")
                                .foregroundColor(Color(red: 0x02/255, green: 0x3E/255, blue: 0x8A/255))
                        }
                    }
                    .accessibilityHint("Opens the street map. Drag one finger to explore streets by touch, two fingers to pan")

                    NavigationLink {
                        SpatialAudioSimulationView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Street Crossing Audio")
                                    .font(.headline)
                                Text("Judge a four-way signal by ear at Congress and High")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "ear.and.waveform")
                                .foregroundColor(.blue)
                        }
                    }
                    .accessibilityHint("Listen to traffic on all four legs of a real intersection and work out when it is safe to cross. Headphones needed")
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
