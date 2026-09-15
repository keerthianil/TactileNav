//
//  MapOptionsScreen.swift
//  TactileNav
//
//  "Create map for…" — choosing what the map will be before it is made.
//
//  The step between finding a place and reading it, and the one the reference tool builds its
//  whole workflow around. It exists because the answers genuinely change the map rather than
//  decorating it: at one scale a screen holds a junction, at another several blocks; with paths
//  switched on the same corner goes from four lines to twenty. Deciding once, up front, is also
//  what keeps the map itself free of controls — there is nothing to adjust while a finger is
//  reading, which is when adjusting anything is most disruptive.
//
//  A paper size is deliberately not offered. On paper it sets how much sheet there is to fill;
//  here the screen is the sheet and its size is not ours to choose, so the only honest control
//  is the scale.
//

import SwiftUI

struct MapOptionsScreen: View {

    let place: SearchResult

    @State private var scale: MapScale = .standard
    @State private var units: DistanceUnit = .feet
    @State private var features: MapFeatureSet = .default

    /// The map, once built. **This screen owns the push to it, rather than the search screen
    /// doing both.** Two `navigationDestination(item:)` modifiers on one view are ambiguous:
    /// with both bindings set, SwiftUI put the map *in place of* this screen instead of on top
    /// of it, so going back from the map skipped straight past the options. One screen, one
    /// binding, one destination.
    @State private var built: BuiltMap?
    @State private var isBuilding = false

    private struct BuiltMap: Identifiable, Hashable {
        let id: String
        let configuration: MapConfiguration
        let map: StreetMap

        static func == (a: BuiltMap, b: BuiltMap) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create map for")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(place.name)
                        .font(.title3.weight(.semibold))
                    Text(place.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Create map for \(place.spokenLabel)")
            }

            Section("Map Scale") {
                Picker("Map Scale", selection: $scale) {
                    ForEach(MapScale.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Map scale")
                Text(scale.explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    // The ratio is what the picker says; what it *means* under a finger is what
                    // a reader can act on, so the two are one announcement rather than two.
                    .accessibilityLabel("\(scale.label). \(scale.explanation) across the screen.")
            }

            Section("Distance Units") {
                Picker("Distance Units", selection: $units) {
                    ForEach(DistanceUnit.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Distance units")
            }

            Section {
                ForEach(MapSurfaceCategory.allCases, id: \.self) { category in
                    Toggle(isOn: binding(for: category)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.label)
                            Text(category.explanation)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityLabel(category.label)
                    .accessibilityHint(category.explanation)
                }
            } header: {
                Text("Features")
            } footer: {
                Text("Every line switched on is another one to tell apart by touch. "
                     + "Streets alone is the clearest map; add the rest when you need them.")
            }

        }
        .navigationDestination(item: $built) { built in
            ExplorerMapScreen(map: built.map, configuration: built.configuration,
                              onLeave: { self.built = nil })
        }
        // Not "Create Map": that is the button in the same bar, and the list already says
        // "Create map for <place>" in its first row. Three of the same two words on one screen
        // is three stops for a VoiceOver reader and one crowded bar for everyone else.
        .navigationTitle("Map Options")
        .navigationBarTitleDisplayMode(.inline)
        // In the bar rather than at the foot of the list, and not only because that is where
        // the reference tool puts it. A list this long scrolls, and a primary action below the
        // fold is one a VoiceOver reader reaches by swiping through every single option first —
        // and one that, on a short screen, SwiftUI has not even built yet.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: create) {
                    Text("Create Map").fontWeight(.semibold)
                }
                .disabled(features.isEmpty || isBuilding)
                .accessibilityIdentifier("createMap")
                .accessibilityLabel("Create map")
                .accessibilityHint(features.isEmpty
                    ? "Switch on at least one feature first"
                    : "Opens the tactile map of \(place.name) at \(scale.label), showing \(features.spoken)")
            }
        }
    }

    /// Builds the map these options describe, then pushes it.
    ///
    /// A fresh parse rather than a filter over an already-loaded map: the scale is baked into
    /// every projected point and into the spatial index, so another scale is a different map,
    /// not a different view of the same one. Off the main thread for the same reason the first
    /// load is — six thousand elements is a dropped frame otherwise.
    private func create() {
        guard !isBuilding, !features.isEmpty else { return }
        isBuilding = true
        let configuration = MapConfiguration(place: place, scale: scale,
                                             units: units, features: features)
        let context = PortlandMapLoader.LoadContext.current(scale: scale)
        let chosen = features
        Task.detached(priority: .userInitiated) {
            let map = try? PortlandMapLoader.loadStreetMap(
                context: context,
                resource: PortlandMapLoader.peninsulaResourceName,
                features: chosen)
            await MainActor.run {
                isBuilding = false
                guard let map else { return }
                built = BuiltMap(id: configuration.id, configuration: configuration, map: map)
            }
        }
    }

    /// A toggle per category, over an option set.
    private func binding(for category: MapSurfaceCategory) -> Binding<Bool> {
        Binding(
            get: { features.contains(category) },
            set: { isOn in
                let bit = MapFeatureSet(category: category)
                if isOn { features.insert(bit) } else { features.remove(bit) }
            }
        )
    }
}

// MARK: - The answers

/// Everything chosen on this screen, in one value the map can be built from.
nonisolated struct MapConfiguration: Hashable, Identifiable {
    let place: SearchResult
    let scale: MapScale
    let units: DistanceUnit
    let features: MapFeatureSet

    var id: String { "\(place.id)|\(scale.rawValue)|\(units.rawValue)|\(features.rawValue)" }

    /// Said on arrival, once the map is up. Everything here is a fact the reader chose and
    /// cannot otherwise check by touch: which way is up, how much ground is on the screen, and
    /// what is drawn on it.
    var arrivalSummary: String {
        "\(place.name). Scale \(scale.label), \(scale.explanation.lowercased()) across. "
        + "Showing \(features.spoken). North is up."
    }
}
