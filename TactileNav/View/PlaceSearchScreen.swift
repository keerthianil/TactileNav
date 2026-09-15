//
//  PlaceSearchScreen.swift
//  TactileNav
//
//  Ask for a place, then go and read it.
//
//  This is the half the Congress Square map does not have. That map opens where it opens; this
//  one starts from a question — a street, or the junction of two — and takes you there with the
//  place marked under your finger.
//
//  **VoiceOver owns the voice on this screen.** It is ordinary UI: a text field and a list, read
//  by the screen reader like any other. The app's own speech channel stays silent until the map
//  appears. Announcing a result count here would put a second voice on top of the one already
//  reading the list, which is precisely the overlap the speech channel exists to prevent.
//

import SwiftUI
import TactileMapCore

struct PlaceSearchScreen: View {

    /// Loaded once and handed to the map, so opening a result does not re-parse the extract.
    private struct Loaded {
        let map: StreetMap
        let index: PlaceSearchIndex
    }

    private enum LoadPhase {
        case loading
        case ready(Loaded)
        case failed
    }

    /// Carries the whole result and the whole map, for the reason spelled out in
    /// `PortlandMapScreen.OpenJunction`: a destination builder that can come up empty is how
    /// SwiftUI is told to throw the navigation stack away.
    private struct OpenPlace: Identifiable, Hashable {
        let id: String
        let result: SearchResult
        let map: StreetMap

        static func == (a: OpenPlace, b: OpenPlace) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    @State private var phase: LoadPhase = .loading
    @State private var hasAppeared = false
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var recents = RecentSearches()
    @State private var openPlace: OpenPlace?

    var body: some View {
        content
            // Unconditional, and total — see `OpenPlace`.
            .navigationDestination(item: $openPlace) { place in
                MapOptionsScreen(place: place.result)
            }
            .navigationTitle("Portland Explorer")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                load()
            }
            // Re-running the search is `.task(id:)`'s job: changing the query cancels the
            // previous run, so the sleep below is a debounce with nothing to bookkeep.
            .task(id: query) { await search() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Loading Portland")
                .accessibilityLabel("Loading the Portland map")

        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("The Portland map could not be loaded.").multilineTextAlignment(.center)
            }
            .padding()
            .accessibilityElement(children: .combine)

        case .ready:
            searchList
        }
    }

    private var searchList: some View {
        List {
            Section {
                TextField("Search Portland", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .accessibilityLabel("Search Portland")
                    .accessibilityHint("A street name, or two street names for a junction")
            }

            if query.isEmpty {
                if !recents.queries.isEmpty {
                    Section("Recent") {
                        ForEach(recents.queries, id: \.self) { past in
                            Button(past) { query = past }
                                .accessibilityHint("Searches for this again")
                        }
                    }
                }
                Section {
                    Text("Try a street — \u{201C}Congress\u{201D} — or two for a junction, "
                         + "like \u{201C}Congress and High\u{201D}.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if results.isEmpty {
                Section {
                    Text(query.count < PlaceSearchIndex.minimumQueryLength
                         ? "Keep typing."
                         : "Nothing here by that name.")
                        .foregroundColor(.secondary)
                }
            } else {
                // Grouped so the answer you probably meant is under a heading you can jump to
                // with the VoiceOver rotor rather than swiping past everything above it.
                ForEach(SearchResult.Kind.allCases, id: \.self) { kind in
                    let group = results.filter { $0.kind == kind }
                    if !group.isEmpty {
                        Section(kind.heading) {
                            ForEach(group) { result in row(result) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ result: SearchResult) -> some View {
        Button {
            open(result)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(result.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        // One element, one swipe: the name and what it is are a single fact, and hearing them
        // as two stops rather than one is slower for no gain.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.spokenLabel)
        .accessibilityHint("Opens the tactile map here")
    }

    // MARK: Behaviour

    private func open(_ result: SearchResult) {
        guard case .ready(let loaded) = phase, openPlace == nil else { return }
        recents.remember(query)
        openPlace = OpenPlace(id: result.id, result: result, map: loaded.map)
    }

    private func search() async {
        guard case .ready(let loaded) = phase else { return }
        guard query.count >= PlaceSearchIndex.minimumQueryLength else {
            results = []
            return
        }
        // Long enough that typing does not re-rank the list under the reading finger on every
        // keystroke, short enough that stopping feels like an answer rather than a wait. Same
        // reasoning, and nearly the same number, as the speech dwell.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        results = loaded.index.results(for: query)
    }

    private func load() {
        let context = PortlandMapLoader.LoadContext.current()
        Task.detached(priority: .userInitiated) {
            guard let map = try? PortlandMapLoader.loadStreetMap(
                context: context,
                resource: PortlandMapLoader.peninsulaResourceName) else {
                await MainActor.run { phase = .failed }
                return
            }
            // Built on the same background pass as the map: it is derived from it, and doing it
            // here keeps the first keystroke from paying for it.
            let index = PlaceSearchIndex(map: map)
            await MainActor.run { phase = .ready(Loaded(map: map, index: index)) }
        }
    }
}

// MARK: - Recent searches

/// The last few things looked for, kept across launches.
///
/// Worth its twenty lines in a research app: running the same set of places past one participant
/// after another is the normal way these sessions go, and retyping a street name with VoiceOver
/// on is slow enough to be worth not doing twice.
@MainActor
struct RecentSearches {
    private static let key = "PortlandExplorer.recentSearches"
    private static let limit = 6

    private(set) var queries: [String] =
        UserDefaults.standard.stringArray(forKey: RecentSearches.key) ?? []

    mutating func remember(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= PlaceSearchIndex.minimumQueryLength else { return }
        queries.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        queries.insert(text, at: 0)
        if queries.count > Self.limit { queries.removeLast(queries.count - Self.limit) }
        UserDefaults.standard.set(queries, forKey: Self.key)
    }
}
