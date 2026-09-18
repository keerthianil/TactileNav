//
//  PlaceSearchScreen.swift
//  TactileNav
//
//  "Where are you traveling?" — ask for anywhere, and the map is fetched for it.
//
//  The other map in this app ships as a file. This one starts from a question, because there is
//  no list of everywhere: what is typed goes to OpenStreetMap's own geocoder, the answer picks a
//  point, and the street network around that point is fetched from Overpass and built into the
//  same kind of map.
//
//  **A postcode is the most useful thing to be able to type.** Somebody planning a journey knows
//  the district long before they know the corner, and a postcode is how people say a district.
//  It is also ambiguous worldwide — 02119 is in Boston, Vilnius and Seoul — so every result
//  carries its full place name and the reader chooses. Guessing a country would be wrong more
//  often than it helped, and silently so.
//
//  **Searching happens on submit, not on every keystroke.** Nominatim is free infrastructure
//  that asks for about one call a second, and firing one per letter would both abuse it and
//  re-order the list under a reading finger. It is also simply clearer: you type, you search.
//
//  VoiceOver owns the voice on this screen — it is a text field and a list. The app's own speech
//  channel stays silent until the map appears, which is the rule that keeps two voices from
//  talking at once.
//

import SwiftUI

struct PlaceSearchScreen: View {

    @State private var query = ""
    @State private var results: [GeocodedPlace] = []
    @State private var isSearching = false
    @State private var message: String?
    @State private var recents = RecentSearches()
    @State private var openPlace: OpenPlace?
    @FocusState private var fieldFocused: Bool

    /// Carries the whole place, for the reason set out in `PortlandMapScreen.OpenJunction`: a
    /// destination builder that can come up empty is how SwiftUI is told to empty the stack.
    private struct OpenPlace: Identifiable, Hashable {
        let id: String
        let place: GeocodedPlace

        static func == (a: OpenPlace, b: OpenPlace) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    TextField("Where are you traveling?", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .submitLabel(.search)
                        .focused($fieldFocused)
                        .onSubmit(search)
                        .accessibilityLabel("Where are you traveling?")
                        .accessibilityHint("A postcode, a street, a landmark or an address")

                    Button("Search", action: search)
                        .buttonStyle(.borderedProminent)
                        .disabled(query.trimmingCharacters(in: .whitespaces).count < 2 || isSearching)
                        .accessibilityIdentifier("runSearch")
                }
            } footer: {
                Text("Try a postcode — \u{201C}04101\u{201D} — or a street, a landmark, an address. "
                     + "Anywhere OpenStreetMap has mapped.")
            }

            if isSearching {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching OpenStreetMap\u{2026}")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Searching OpenStreetMap")
                }
            }

            if let message {
                Section {
                    Text(message)
                        .foregroundColor(.secondary)
                        .accessibilityLabel(message)
                }
            }

            if !results.isEmpty {
                Section("Results") {
                    ForEach(results) { place in row(place) }
                }
            }

            if results.isEmpty, !isSearching, !recents.queries.isEmpty {
                Section("Recent") {
                    ForEach(recents.queries, id: \.self) { past in
                        Button(past) {
                            query = past
                            search()
                        }
                        .accessibilityHint("Searches for this again")
                    }
                }
            }
        }
        .navigationDestination(item: $openPlace) { open in
            MapOptionsScreen(place: open.place)
        }
        .navigationTitle("Find a Place")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ place: GeocodedPlace) -> some View {
        Button {
            guard openPlace == nil else { return }
            recents.remember(query)
            openPlace = OpenPlace(id: place.id, place: place)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.body)
                    .foregroundColor(.primary)
                if !place.context.isEmpty {
                    Text(place.context)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(place.kind.replacingOccurrences(of: "_", with: " ").capitalized
                     + (LiveMapService.isCached(place) ? " \u{00B7} already downloaded" : ""))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        // One element, one swipe: the name, where it is, and what kind of thing it is are one
        // fact, and hearing them as three stops is slower for no gain.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(place.spokenLabel)
        .accessibilityHint(LiveMapService.isCached(place)
            ? "Already downloaded. Opens the map options"
            : "Opens the map options, then downloads the streets around it")
    }

    // MARK: Searching

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, !isSearching else { return }
        fieldFocused = false
        isSearching = true
        message = nil
        results = []

        Task {
            do {
                let found = try await OSMGeocoder.search(text)
                isSearching = false
                results = found
            } catch {
                isSearching = false
                // The geocoder's own words: it knows whether this was no network, a service
                // that would not answer, or a name that simply is not there.
                message = (error as? LocalizedError)?.errorDescription
                    ?? "That search could not be completed."
            }
        }
    }
}

// MARK: - Recent searches

/// The last few things looked for, kept across launches.
///
/// Worth its twenty lines in a research app: running the same places past one participant after
/// another is how these sessions go, and retyping a postcode with VoiceOver on is slow enough to
/// be worth not doing twice.
@MainActor
struct RecentSearches {
    private static let key = "PlaceSearch.recentQueries"
    private static let limit = 6

    private(set) var queries: [String] =
        UserDefaults.standard.stringArray(forKey: RecentSearches.key) ?? []

    mutating func remember(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return }
        queries.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        queries.insert(text, at: 0)
        if queries.count > Self.limit { queries.removeLast(queries.count - Self.limit) }
        UserDefaults.standard.set(queries, forKey: Self.key)
    }
}
