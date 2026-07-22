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
                                Text("Tactile map of downtown Portland with time-of-day traffic and APS crossings")
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
