import SwiftUI
import JellyCore

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.phase {
            case .starting:
                ZStack {
                    Theme.Colors.background.ignoresSafeArea()
                    ProgressView().tint(Theme.Colors.accent)
                }
            case .connect:
                ConnectView()
            case .login(let url, let name):
                LoginView(serverURL: url, serverName: name)
                    .id(url)
            case .ready:
                MainTabs()
            }
        }
        .fullScreenCover(item: $app.playing, onDismiss: { app.playerDidClose() }) { request in
            PlayerView(request: request)
        }
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            BrowseView(kind: .movies)
                .tabItem { Label("Film", systemImage: "film.fill") }
            BrowseView(kind: .series)
                .tabItem { Label("Serie TV", systemImage: "tv.fill") }
            BrowseView(kind: .documentaries)
                .tabItem { Label("Documentari", systemImage: "globe.europe.africa.fill") }
            SearchView()
                .tabItem { Label("Cerca", systemImage: "magnifyingglass") }
        }
        .tint(Theme.Colors.accent)
    }
}

struct ComingSoonView: View {
    let title: String
    let icon: String
    let text: String

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: icon)
                    .font(.largeTitle)
                    .foregroundStyle(Theme.Colors.accent)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Colors.background)
            .navigationTitle(title)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pendingCount = 0

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Utente", value: app.account?.userName ?? "")
                    LabeledContent("Server", value: app.account?.serverName ?? "")
                    LabeledContent("Indirizzo", value: app.account?.serverURL.absoluteString ?? "")
                }
                Section {
                    Picker("Audio", selection: $app.audioPreference) {
                        ForEach(AudioPreference.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Sottotitoli", selection: $app.subtitlePreference) {
                        ForEach(SubtitlePreference.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Lingua")
                } footer: {
                    Text("Usate quando premi Riproduci. Con i sottotitoli spenti compaiono comunque quelli \"forzati\" (dialoghi in altre lingue). Nella scheda del film puoi scegliere tracce diverse.")
                }
                Section {
                    Picker("Player", selection: $app.playerPreference) {
                        ForEach(PlayerPreference.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                } header: {
                    Text("Riproduzione")
                } footer: {
                    Text("Automatico usa il player Apple quando il file lo permette e VLC per tutto il resto (MKV, DTS, sottotitoli PGS…). La conversione sul server si usa solo se entrambi falliscono.")
                }
                Section {
                    LabeledContent("Posizioni da inviare", value: "\(pendingCount)")
                    Button("Invia ora") {
                        Task {
                            await app.progress.flush()
                            pendingCount = await app.progress.pendingItems.count
                        }
                    }
                } header: {
                    Text("Sincronizzazione")
                } footer: {
                    Text("Le posizioni vengono salvate sul telefono e inviate al server appena possibile.")
                }
                Section {
                    Button("Esci", role: .destructive) { app.logout() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.background)
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .task { pendingCount = await app.progress.pendingItems.count }
        }
    }
}
