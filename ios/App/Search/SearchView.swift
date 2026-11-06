import SwiftUI
import JellyCore

/// S09: results while typing, split into films, series and documentaries.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var results: [BaseItem] = []
    @State private var searching = false
    @State private var error: String?
    @State private var searchedTerm = ""
    @State private var recent = Prefs.recentSearches

    private let columns = [GridItem(.adaptive(minimum: Theme.Size.gridPosterMin), spacing: Theme.Space.m)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if text.trimmingCharacters(in: .whitespaces).isEmpty {
                        recentSection
                    } else if let error {
                        ErrorBanner(message: error) { Task { await run(text) } }
                    } else if results.isEmpty && !searching && searchedTerm == text {
                        Text("Nessun risultato per “\(text)”.")
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(Theme.Space.xxl)
                    } else {
                        group("Film", results.filter { $0.isMovie && !isDocumentary($0) })
                        group("Serie TV", results.filter { $0.isSeries && !isDocumentary($0) })
                        group("Documentari", results.filter(isDocumentary))
                    }
                }
                .padding(.vertical, Theme.Space.l)
            }
            .overlay(alignment: .top) {
                if searching { ProgressView().tint(Theme.Colors.accent).padding(.top, Theme.Space.s) }
            }
            .background(Theme.Colors.background)
            .navigationTitle("Cerca")
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Film, serie, documentari")
            .autocorrectionDisabled()
            .onSubmit(of: .search) { remember(text) }
            .task(id: text) {
                // Wait for a pause in typing; a new letter cancels this search.
                let term = text
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await run(term)
            }
            .withTitleDestinations()
        }
    }

    private func isDocumentary(_ item: BaseItem) -> Bool {
        (item.genres ?? []).contains { GenreGroup.documentary.contains($0) }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [BaseItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .padding(.horizontal, Theme.Space.l)
                LazyVGrid(columns: columns, spacing: Theme.Space.l) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            GeometryReader { geo in
                                PosterCard(item: item, api: app.api, width: geo.size.width)
                            }
                            .aspectRatio(2 / 3.6, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded { remember(text) })
                    }
                }
                .padding(.horizontal, Theme.Space.l)
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if recent.isEmpty {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.Colors.accent)
                Text("Cerca per titolo in tutta la libreria.")
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(Theme.Space.xxl)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text("Ricerche recenti")
                        .font(.headline)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Spacer()
                    Button("Cancella") {
                        recent = []
                        Prefs.recentSearches = []
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.accent)
                }
                ForEach(recent, id: \.self) { term in
                    Button {
                        text = term
                    } label: {
                        Label(term, systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Theme.Space.s)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.l)
        }
    }

    private func run(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let api = app.api else {
            results = []
            searchedTerm = term
            return
        }
        searching = true
        defer { searching = false }
        do {
            let found = try await api.search(trimmed)
            guard term == text else { return }  // the user kept typing
            results = found
            error = nil
            searchedTerm = term
        } catch is CancellationError {
            return
        } catch {
            if term == text { self.error = error.localizedDescription }
        }
    }

    private func remember(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return }
        recent = [t] + recent.filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        Prefs.recentSearches = recent
    }
}
