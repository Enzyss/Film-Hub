import SwiftUI
import JellyCore

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var model = HomeModel()
    @State private var path = NavigationPath()
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                    categories

                    if let error = model.errorMessage {
                        ErrorBanner(message: error) { Task { await reload() } }
                    }

                    if !model.hasLoadedOnce {
                        skeletonRow(title: "Continua a guardare")
                        skeletonRow(title: "Prossimi episodi")
                    } else if model.isEmpty {
                        emptyState
                    } else {
                        row(title: "Continua a guardare", items: model.content.resume)
                        row(title: "Prossimi episodi", items: model.content.nextUp)
                    }
                }
                .padding(.vertical, Theme.Space.l)
            }
            .background(Theme.Colors.background)
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                        .accessibilityLabel("Impostazioni")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .refreshable { await reload() }
            .task(id: app.homeRefreshToken) { await reload() }
            .withTitleDestinations()
        }
    }

    /// Shortcuts to sections without a tab of their own (five tabs fit).
    private var categories: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                NavigationLink(value: CatalogKind.documentaries) {
                    Label("Documentari", systemImage: "globe.europe.africa.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.s)
                        .background(Theme.Colors.surface)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Space.l)
        }
    }

    /// Episodes open their series' page.
    private func titlePage(for item: BaseItem) -> BaseItem {
        guard item.isEpisode, let sid = item.seriesId else { return item }
        return BaseItem(id: sid, name: item.seriesName, type: "Series")
    }

    private func reload() async {
        await model.load(api: app.api) { app.sessionExpired() }
    }

    @ViewBuilder
    private func row(title: String, items: [BaseItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .padding(.horizontal, Theme.Space.l)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Space.m) {
                        ForEach(items) { item in
                            // A tap resumes at once (the core loop); hold for the title page.
                            Button {
                                app.play(item)
                            } label: {
                                LandscapeCard(item: item, api: app.api)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { app.play(item) } label: { Label("Riprendi", systemImage: "play.fill") }
                                Button { path.append(titlePage(for: item)) } label: {
                                    Label(item.isEpisode ? "Vai alla serie" : "Dettagli", systemImage: "info.circle")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.l)
                }
            }
        }
    }

    private func skeletonRow(title: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.Colors.textPrimary)
                .padding(.horizontal, Theme.Space.l)
            HStack(spacing: Theme.Space.m) {
                SkeletonCard()
                SkeletonCard()
            }
            .padding(.horizontal, Theme.Space.l)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "popcorn")
                .font(.largeTitle)
                .foregroundStyle(Theme.Colors.accent)
            Text("Niente in sospeso")
                .font(.headline)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Quello che inizi a guardare comparirà qui, pronto a ripartire dal punto giusto.")
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xxl)
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.danger)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Riprova", action: retry)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Colors.accent)
        }
        .padding(Theme.Space.m)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .padding(.horizontal, Theme.Space.l)
    }
}
