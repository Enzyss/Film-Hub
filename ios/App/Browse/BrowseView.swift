import SwiftUI
import Observation
import JellyCore

/// Rows of one tab. Shows the last copy at once, then loads every row from the
/// server a few at a time (each takes ~0.7-1.5 s on the user's server).
@MainActor
@Observable
final class CatalogModel {
    let kind: CatalogKind
    let rows: [CatalogRow]
    private(set) var content: [String: [BaseItem]] = [:]
    private(set) var loaded: Set<String> = []
    private(set) var errorMessage: String?
    @ObservationIgnored private var lastLoad = Date.distantPast

    static let rowLimit = 20
    static let parallelRows = 4
    /// A platform or genre with fewer titles than this on the server is hidden.
    static let minRowItems = 4

    init(kind: CatalogKind, anime: AnimeLibraries = .none) {
        self.kind = kind
        self.rows = Catalog.rows(for: kind, anime: anime)
        if let cached = JSONFile.read([String: [BaseItem]].self, from: CachePaths.catalog(kind.rawValue)) {
            content = cached
            loaded = Set(cached.keys)
        }
    }

    var heroItems: [BaseItem] {
        let first = rows.first.flatMap { content[$0.id] } ?? []
        return Array(first.filter(\.hasBackdrop).prefix(6))
    }

    func items(for row: CatalogRow) -> [BaseItem] { content[row.id] ?? [] }

    /// Reloads at most every 5 minutes unless forced (pull to refresh).
    func load(api: JellyfinAPI?, force: Bool = false) async {
        guard let api else { return }
        guard force || Date().timeIntervalSince(lastLoad) > 300 else { return }
        lastLoad = Date()
        errorMessage = nil
        var failures = 0
        let limit = Self.rowLimit
        let parallel = Self.parallelRows
        // A few rows at a time: fast for the user, gentle on the server.
        for chunk in stride(from: 0, to: rows.count, by: parallel) {
            let slice = Array(rows[chunk..<min(chunk + parallel, rows.count)])
            await withTaskGroup(of: (String, [BaseItem]?).self) { group in
                for row in slice {
                    group.addTask {
                        // A few extra to make up for HD/4K duplicates.
                        let items = try? await api.items(row.query, limit: limit + 6)
                        return (row.id, items.map { Array($0.deduplicated().prefix(limit)) })
                    }
                }
                for await (id, items) in group {
                    if let items {
                        content[id] = items
                        loaded.insert(id)
                    } else {
                        failures += 1
                    }
                }
            }
            if Task.isCancelled { return }
        }
        if failures == rows.count {
            errorMessage = "Non riesco a caricare il catalogo. Controlla la connessione."
            lastLoad = .distantPast
        }
        JSONFile.write(content, to: CachePaths.catalog(kind.rawValue))
    }
}

/// A tab with its own navigation.
struct BrowseView: View {
    let kind: CatalogKind
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            BrowseTab(kind: kind)
                .withTitleDestinations()
        }
    }
}

/// Picks the rows: anime need the server's anime libraries, found at sign-in.
struct BrowseTab: View {
    let kind: CatalogKind
    @Environment(AppModel.self) private var app

    var body: some View {
        if kind == .anime {
            if app.animeLibraries.all.isEmpty && (!app.librariesLoaded || app.librariesLoading) {
                ProgressView()
                    .tint(Theme.Colors.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Colors.background)
                    .navigationTitle(kind.title)
            } else if app.animeLibraries.all.isEmpty {
                // The server did not answer: say so instead of an empty page.
                VStack(spacing: Theme.Space.l) {
                    Image(systemName: "sparkles")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.Colors.accent)
                    Text("Non riesco a trovare le librerie anime sul server.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Riprova") { app.reloadLibraries() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.Colors.accent)
                }
                .padding(Theme.Space.xxl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.background)
                .navigationTitle(kind.title)
            } else {
                BrowseContent(kind: kind, anime: app.animeLibraries)
                    .id(app.animeLibraries)  // new rows if the libraries change
            }
        } else {
            BrowseContent(kind: kind)
        }
    }
}

struct BrowseContent: View {
    @Environment(AppModel.self) private var app
    @State private var model: CatalogModel

    init(kind: CatalogKind, anime: AnimeLibraries = .none) {
        _model = State(initialValue: CatalogModel(kind: kind, anime: anime))
    }

    var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.xxl) {
                    if model.heroItems.isEmpty {
                        Color.clear.frame(height: Theme.Space.s)
                    } else {
                        HeroCarousel(items: model.heroItems, api: app.api)
                    }

                    if let error = model.errorMessage {
                        ErrorBanner(message: error) { Task { await model.load(api: app.api, force: true) } }
                    }

                    ForEach(model.rows) { row in
                        let items = model.items(for: row)
                        if items.count >= CatalogModel.minRowItems {
                            ItemRow(title: row.title, items: items, api: app.api,
                                    style: row.style, seeAll: row)
                        } else if !model.loaded.contains(row.id) {
                            SkeletonPosterRow(title: row.title)
                        }
                        // Rows with no titles on this server simply do not show.
                    }
                }
                .padding(.bottom, Theme.Space.xxl)
            }
            .ignoresSafeArea(edges: model.heroItems.isEmpty ? [] : .top)
            .background(Theme.Colors.background)
            .navigationTitle(model.kind.title)
            .toolbarBackground(.hidden, for: .navigationBar)
            .refreshable { await model.load(api: app.api, force: true) }
            .task { await model.load(api: app.api) }
    }
}

/// Every title of one row, as a grid, page after page.
struct SeeAllView: View {
    let row: CatalogRow
    @Environment(AppModel.self) private var app

    @State private var items: [BaseItem] = []
    @State private var seen = Set<String>()
    @State private var cursor = CatalogCursor.start
    @State private var reachedEnd = false
    @State private var loading = false
    @State private var error: String?
    @State private var sortIndex = 0
    @State private var unplayedOnly = false

    static let pageSize = 60

    private var query: CatalogQuery {
        var q = row.query
        if sortIndex > 0 || row.query.sortBy == "Random" {
            let s = Catalog.sorts[sortIndex]
            q.sortBy = s.sortBy
            q.descending = s.descending
        }
        if unplayedOnly { q.unplayedOnly = true }
        return q
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.Size.gridPosterMin), spacing: Theme.Space.m)],
                      spacing: Theme.Space.l) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        GeometryReader { geo in
                            PosterCard(item: item, api: app.api, width: geo.size.width)
                        }
                        .aspectRatio(2 / 3.6, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item.id == items.last?.id { Task { await loadMore() } }
                    }
                }
            }
            .padding(Theme.Space.l)

            if loading {
                ProgressView().tint(Theme.Colors.accent).padding()
            } else if let error {
                ErrorBanner(message: error) { Task { await loadMore() } }
            } else if items.isEmpty && reachedEnd {
                Text("Nessun titolo qui.")
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(Theme.Space.xxl)
            }
        }
        .background(Theme.Colors.background)
        .navigationTitle(row.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Ordina", selection: $sortIndex) {
                        ForEach(Catalog.sorts.indices, id: \.self) { i in
                            Text(Catalog.sorts[i].label).tag(i)
                        }
                    }
                    Toggle("Solo non visti", isOn: $unplayedOnly)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Ordina e filtra")
            }
        }
        .task(id: "\(sortIndex)-\(unplayedOnly)") { await reset() }
    }

    private func reset() async {
        items = []
        seen = []
        cursor = .start
        reachedEnd = false
        error = nil
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, !reachedEnd, let api = app.api else { return }
        loading = true
        defer { loading = false }
        do {
            let q = self.query
            let page = try await api.page(q, cursor: cursor, limit: Self.pageSize)
            cursor = page.next
            if page.next.isFinished(for: q) { reachedEnd = true }
            let fresh = page.items.filter { seen.insert($0.dedupeKey).inserted }
            items.append(contentsOf: fresh)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension View {
    /// Title pages and "see all" grids, for every tab's NavigationStack.
    func withTitleDestinations() -> some View {
        navigationDestination(for: BaseItem.self) { DetailView(item: $0) }
            .navigationDestination(for: CatalogRow.self) { SeeAllView(row: $0) }
            .navigationDestination(for: CatalogKind.self) { BrowseTab(kind: $0) }
    }
}
