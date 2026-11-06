import SwiftUI
import JellyCore

/// S01: where is the server?
struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var address = Prefs.lastServerURL ?? ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        OnboardingScaffold(title: "Collega il tuo server",
                           subtitle: "L'indirizzo che usi per aprire Jellyfin, per esempio jellyfin.miodominio.it o 192.168.1.10:8096.") {
            TextField("Indirizzo del server", text: $address)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)
                .fieldStyle()
                .accessibilityLabel("Indirizzo del server")

            if let error { ErrorText(error) }

            Button(action: submit) {
                if busy { ProgressView().tint(.black) } else { Text("Continua") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await app.connect(to: address)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// S02: who are you?
struct LoginView: View {
    @Environment(AppModel.self) private var app
    let serverURL: URL
    let serverName: String

    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Field { case user, password }

    var body: some View {
        OnboardingScaffold(title: "Accedi a \(serverName)", subtitle: serverURL.absoluteString) {
            TextField("Nome utente", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .user)
                .onSubmit { focus = .password }
                .fieldStyle()

            SecureField("Password", text: $password)
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit(submit)
                .fieldStyle()

            if let error { ErrorText(error) }

            Button(action: submit) {
                if busy { ProgressView().tint(.black) } else { Text("Accedi") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy || username.isEmpty)

            Button("Cambia server") { app.changeServer() }
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.top, Theme.Space.s)
        }
        .onAppear { focus = .user }
    }

    private func submit() {
        guard !busy, !username.isEmpty else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await app.login(serverURL: serverURL, serverName: serverName,
                                    username: username, password: password)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct OnboardingScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.bottom, Theme.Space.s)
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.bottom, Theme.Space.s)
                content
            }
            .frame(maxWidth: Theme.Size.fieldMaxWidth)
            .padding(Theme.Space.xl)
            .padding(.top, Theme.Space.xxl)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.Colors.background.ignoresSafeArea())
    }
}

struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(Theme.Colors.danger)
    }
}
