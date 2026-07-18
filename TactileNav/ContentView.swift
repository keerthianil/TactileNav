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
                                Text("Portland Old Port")
                                    .font(.headline)
                                Text("Tactile map of the Old Port area with traffic and APS data")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "map.fill")
                                .foregroundColor(Color(red: 0x02/255, green: 0x3E/255, blue: 0x8A/255))
                        }
                    }
                    .accessibilityHint("Opens tactile map with drag exploration, haptic feedback, and time-of-day traffic")

                    NavigationLink {
                        SpatialAudioSimulationView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Spatial Audio Simulation")
                                    .font(.headline)
                                Text("Vehicle pass-by with spatial audio and Doppler effect")
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
