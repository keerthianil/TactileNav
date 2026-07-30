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
                                Text("Pannable tactile street map of downtown Portland at true lane scale")
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
                                Text("Vehicle pass-by with real Doppler: straight vs. turning, car vs. EV")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "ear.and.waveform")
                                .foregroundColor(.blue)
                        }
                    }
                    .accessibilityHint("Hear different vehicles passing by with spatial audio using headphones")
                }

                Section("Roux Institute") {
                    NavigationLink("Roux Institute Map",
                                   destination: RTMRouxMapView())
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
