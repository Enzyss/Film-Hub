import Foundation
import Network
import Observation
import UIKit
import JellyCore

/// The app's state: who is signed in, where, and the shared progress sync.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        case connect
        case login(serverURL: URL, serverName: String)
        case ready
    }

    private(set) var phase: Phase = .starting
    private(set) var account: StoredAccount?
    private(set) var api: JellyfinAPI?

    /// Bumped whenever home should reload (foreground, player closed, login).
    private(set) var homeRefreshToken = 0

    /// The item open in the full-screen player, if any.
    var playing: BaseItem?

    var playerPreference: PlayerPreference {
        didSet { Prefs.playerPreference = playerPreference.rawValue }
    }

    let progress = ProgressSync(fileURL: AppPaths.pendingProgress)
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    init() {
        playerPreference = Prefs.playerPreference.flatMap(PlayerPreference.init(rawValue:)) ?? .automatic
    }

    static var clientInfo: ClientInfo {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        return ClientInfo(name: "Film Hub", version: version, deviceName: "iPhone", deviceId: Prefs.deviceId)
    }

    // MARK: Startup

    func bootstrap() async {
        startNetworkMonitor()
        if let saved = JSONFile.read(StoredAccount.self, from: AppPaths.account),
           let token = Keychain.load(account: keychainAccount(saved)) {
            await signIn(account: saved, token: token)
            return
        }
        phase = .connect
    }

    private func keychainAccount(_ a: StoredAccount) -> String {
        "\(a.serverURL.absoluteString)|\(a.userId)"
    }

    private func signIn(account: StoredAccount, token: String) async {
        let api = JellyfinAPI(baseURL: account.serverURL, client: Self.clientInfo)
            .authorized(token: token, userId: account.userId)
        self.account = account
        self.api = api
        await progress.setTransport(api)
        phase = .ready
        homeRefreshToken += 1
        Task { await progress.flush() }
    }

    // MARK: S01 Connect

    /// Tries each URL the address could mean; returns the first that answers as Jellyfin.
    func connect(to input: String) async throws {
        let candidates = ServerAddress.candidates(from: input)
        guard !candidates.isEmpty else { throw JellyfinError.invalidAddress }
        var lastError: Error = JellyfinError.invalidAddress
        for url in candidates {
            do {
                let info = try await JellyfinAPI(baseURL: url, client: Self.clientInfo).publicInfo()
                Prefs.lastServerURL = url.absoluteString
                phase = .login(serverURL: url, serverName: info.serverName ?? url.host ?? "Jellyfin")
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func changeServer() {
        phase = .connect
    }

    // MARK: S02 Login

    func login(serverURL: URL, serverName: String, username: String, password: String) async throws {
        let api = JellyfinAPI(baseURL: serverURL, client: Self.clientInfo)
        let result = try await api.authenticate(username: username, password: password)
        guard let token = result.accessToken, let user = result.user else { throw JellyfinError.unauthorized }
        let account = StoredAccount(serverURL: serverURL, serverId: result.serverId, serverName: serverName,
                                    userId: user.id, userName: user.name ?? username)
        JSONFile.write(account, to: AppPaths.account)
        Keychain.save(token, account: keychainAccount(account))
        await signIn(account: account, token: token)
    }

    func logout() {
        if let account { Keychain.delete(account: keychainAccount(account)) }
        JSONFile.delete(AppPaths.account)
        JSONFile.delete(AppPaths.homeCache)
        let serverURL = account?.serverURL
        let serverName = account?.serverName
        account = nil
        api = nil
        Task { await progress.setTransport(nil) }
        if let serverURL, let serverName {
            phase = .login(serverURL: serverURL, serverName: serverName)
        } else {
            phase = .connect
        }
    }

    /// Called when the server rejects the saved token.
    func sessionExpired() {
        guard phase == .ready else { return }
        logout()
    }

    // MARK: Lifecycle

    func didBecomeActive() {
        guard phase == .ready else { return }
        Task { await progress.flush() }
        homeRefreshToken += 1
    }

    func playerDidClose() {
        playing = nil
        // Give the "stopped" report a moment to land, then reload home.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            await progress.flush()
            homeRefreshToken += 1
        }
    }

    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.phase == .ready else { return }
                await self.progress.flush()
            }
        }
        monitor.start(queue: DispatchQueue(label: "filmhub.network"))
        pathMonitor = monitor
    }
}
