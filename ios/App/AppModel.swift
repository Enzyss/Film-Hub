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

    /// What the full-screen player is showing, if anything.
    var playing: PlayRequest?

    /// The running playback. Outlives the player screen while in Picture in
    /// Picture, so the film keeps going while you browse or use other apps.
    @ObservationIgnored private(set) var activePlayer: PlayerModel?

    var playerPreference: PlayerPreference {
        didSet { Prefs.playerPreference = playerPreference.rawValue }
    }
    var audioPreference: AudioPreference {
        didSet { Prefs.audioPreference = audioPreference.rawValue }
    }
    var subtitlePreference: SubtitlePreference {
        didSet { Prefs.subtitlePreference = subtitlePreference.rawValue }
    }

    let progress = ProgressSync(fileURL: AppPaths.pendingProgress)
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    init() {
        playerPreference = Prefs.playerPreference.flatMap(PlayerPreference.init(rawValue:)) ?? .automatic
        audioPreference = Prefs.audioPreference.flatMap(AudioPreference.init(rawValue:)) ?? .italian
        subtitlePreference = Prefs.subtitlePreference.flatMap(SubtitlePreference.init(rawValue:)) ?? .off
    }

    /// Opens the player. `choice` and `source` come from the title page; from
    /// a home card they are worked out from the language preferences.
    func play(_ item: BaseItem, source: MediaSource? = nil, choice: TrackChoice? = nil,
              prefetched: PlayRequest.Prefetched? = nil) {
        // A new film replaces one still running in PiP.
        if let active = activePlayer, active.isPiPActive {
            active.close()
            activePlayer = nil
        }
        playing = PlayRequest(item: item, source: source, choice: choice, prefetched: prefetched)
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

    /// The model for a player screen: the running one if the screen comes back
    /// from PiP, else a new one (ending whatever played before).
    func player(for request: PlayRequest, api: JellyfinAPI) -> PlayerModel {
        if let current = activePlayer, current.request.id == request.id { return current }
        activePlayer?.close()
        let model = PlayerModel(request: request, api: api, sync: progress, preference: playerPreference,
                                audio: audioPreference, subtitles: subtitlePreference)
        model.onPiPStarted = { [weak self] in
            // Free the screen: the film goes on in the PiP window.
            self?.playing = nil
        }
        model.onPiPRestore = { [weak self, weak model] in
            guard let self, let model else { return }
            self.playing = model.request
        }
        model.onPiPClosed = { [weak self, weak model] in
            guard let self, let model else { return }
            model.close()
            if self.activePlayer === model { self.activePlayer = nil }
            if self.playing?.id == model.request.id { self.playing = nil }
            self.refreshAfterPlayback()
        }
        activePlayer = model
        return model
    }

    func playerDidClose() {
        // Dismissed because PiP started: the film is still playing.
        if let active = activePlayer, active.isPiPActive { return }
        activePlayer?.close()
        activePlayer = nil
        refreshAfterPlayback()
    }

    private func refreshAfterPlayback() {
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
