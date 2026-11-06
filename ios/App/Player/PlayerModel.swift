import Foundation
import Observation
import UIKit
import JellyCore

/// Drives one playback: picks the route, watches for stalls, reports progress.
@MainActor
@Observable
final class PlayerModel {
    enum Phase: Equatable {
        case preparing
        case playing
        case paused
        case buffering
        case reconnecting
        case ended
        case failed(String)
    }

    let item: BaseItem
    private(set) var phase: Phase = .preparing
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var routeLabel = ""
    private(set) var engine: (any PlaybackEngine)?
    /// What the user sees while the video opens. Never a silent black screen.
    private(set) var openingMessage = "Apertura…"
    /// Seconds from the tap to the first frame, shown next to the route label.
    private(set) var openSeconds: Double?

    // In-player audio and subtitle menu, as the engine names the tracks.
    private(set) var audioOptions: [EngineTrack] = []
    private(set) var subtitleOptions: [EngineTrack] = []
    private(set) var currentAudio: Int?
    private(set) var currentSubtitle: Int?

    @ObservationIgnored private let api: JellyfinAPI
    @ObservationIgnored private let sync: ProgressSync
    @ObservationIgnored private let preference: PlayerPreference
    @ObservationIgnored private let request: PlayRequest
    @ObservationIgnored private let audioPreference: AudioPreference
    @ObservationIgnored private let subtitlePreference: SubtitlePreference
    @ObservationIgnored private var startTracks: StartTracks = .none
    @ObservationIgnored private var lastTrackRefresh = Date.distantPast

    @ObservationIgnored private var routes: [PlaybackRoute] = []
    @ObservationIgnored private var routeIndex = 0
    @ObservationIgnored private var mediaSourceId: String?
    @ObservationIgnored private var playSessionId: String?
    @ObservationIgnored private var runTimeTicks: Int64?

    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var wantsToPlay = true
    @ObservationIgnored private var lastAdvanceAt = Date()
    @ObservationIgnored private var lastSeenPosition: Double = -1
    @ObservationIgnored private var hasPlayedAnything = false
    @ObservationIgnored private var lastReportAt = Date.distantPast
    @ObservationIgnored private var reloadsInARow = 0
    @ObservationIgnored private var smoothSince = Date()
    @ObservationIgnored private var startedReported = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private let tappedAt = Date()
    @ObservationIgnored private var routeOpenedAt = Date()

    /// No progress for this long while trying to play = stalled (P1).
    static let stallTimeout: TimeInterval = 12
    /// Measured on the user's server: a new MKV opens in ~3-6 s, server HLS in
    /// ~3.5 s. Past 15 s the route is not going to open: try the next one
    /// instead of leaving a black screen.
    static let openTimeout: TimeInterval = 15
    /// After this long, tell the user we are still working on it.
    static let slowOpenNotice: TimeInterval = 6
    static let reportInterval: TimeInterval = 10
    static let maxReloads = 3

    init(request: PlayRequest, api: JellyfinAPI, sync: ProgressSync, preference: PlayerPreference,
         audio: AudioPreference, subtitles: SubtitlePreference) {
        self.request = request
        self.item = request.item
        self.api = api
        self.sync = sync
        self.preference = preference
        self.audioPreference = audio
        self.subtitlePreference = subtitles
        self.runTimeTicks = request.item.runTimeTicks
    }

    var isPlaying: Bool { phase == .playing || phase == .buffering }

    // MARK: Start

    func start() async {
        phase = .preparing
        let startSeconds = item.resumeSeconds
        position = startSeconds
        do {
            try await prepareRoutes(startSeconds: startSeconds)
        } catch JellyfinError.unauthorized {
            phase = .failed(JellyfinError.unauthorized.localizedDescription)
            return
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        guard !closed else { return }
        guard !routes.isEmpty else {
            phase = .failed("Nessun modo di riprodurre questo file.")
            return
        }
        routeIndex = 0
        open(at: startSeconds)
        startTicking()
    }

    private func prepareRoutes(startSeconds: Double) async throws {
        var source: MediaSource?
        let wantedSource = request.source?.id
        do {
            let info: PlaybackInfoResponse
            if let pre = request.prefetched, pre.matches(choice: request.choice, mediaSourceId: wantedSource) {
                info = pre.info  // fetched while the title page was open
            } else {
                info = try await api.playbackInfo(itemId: item.id, startTicks: Ticks.fromSeconds(startSeconds),
                                                  mediaSourceId: wantedSource, choice: request.choice)
            }
            source = info.mediaSources?.first { $0.id == wantedSource } ?? info.mediaSources?.first
            playSessionId = info.playSessionId
        } catch JellyfinError.unauthorized {
            throw JellyfinError.unauthorized
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // PlaybackInfo failed (old server, odd policy): fall back to the
            // item's own sources and play the file directly with VLC.
            let full = try await api.item(id: item.id)
            source = full.mediaSources?.first
        }
        guard let source else { throw JellyfinError.http(404) }
        mediaSourceId = source.id
        if let rt = source.runTimeTicks, rt > 0 { runTimeTicks = rt }

        let choice = request.choice
            ?? Tracks.defaultChoice(for: source, audio: audioPreference, subtitles: subtitlePreference)
        startTracks = makeStartTracks(choice: choice, source: source)

        let compatible = PlaybackDecider.isAppleCompatible(source)
        guard let staticURL = api.staticStreamURL(itemId: item.id, mediaSourceId: source.id,
                                                  playSessionId: playSessionId),
              let appleURL = api.staticStreamURL(itemId: item.id, mediaSourceId: source.id,
                                                 playSessionId: playSessionId,
                                                 fileExtension: PlaybackDecider.appleExtension(for: source))
        else { throw JellyfinError.invalidAddress }

        routes = PlaybackDecider.routes(
            appleCompatible: compatible,
            appleStaticURL: appleURL,
            staticURL: staticURL,
            transcodeURL: api.transcodeURL(source.transcodingUrl),
            preference: preference,
            needsTrackControl: Tracks.needsTrackControl(choice, source: source)
        )
    }

    /// Jellyfin stream numbers -> what VLC needs at start.
    private func makeStartTracks(choice: TrackChoice, source: MediaSource) -> StartTracks {
        var t = StartTracks()
        let audio = Tracks.audio(source)
        if choice.audioIndex != source.defaultAudioStream?.index {
            t.audioPosition = Tracks.vlcPosition(of: choice.audioIndex, in: audio)
        }
        let subs = Tracks.subtitles(source)
        if let idx = choice.subtitleIndex, let stream = subs.first(where: { $0.index == idx }) {
            if stream.isExternal == true, let msid = source.id {
                let format = (stream.codec ?? "").lowercased() == "ass" ? "ass" : "srt"
                t.externalSubtitle = api.subtitleURL(itemId: item.id, mediaSourceId: msid, index: idx, format: format)
            } else {
                t.subtitlePosition = Tracks.vlcPosition(of: idx, in: subs)
            }
        } else {
            t.subtitlesOff = true
        }
        return t
    }

    private func open(at seconds: Double) {
        guard routeIndex < routes.count else {
            phase = .failed("Il file non si apre con nessuno dei player disponibili.")
            return
        }
        let route = routes[routeIndex]
        engine?.stop()
        let newEngine: any PlaybackEngine = route.usesVLC ? VLCEngine() : AppleEngine()
        engine = newEngine
        routeLabel = route.label
        openingMessage = routeIndex == 0 ? "Apertura…" : "Provo un altro modo (\(route.label))…"
        hasPlayedAnything = false
        lastSeenPosition = -1
        lastAdvanceAt = Date()
        routeOpenedAt = Date()
        newEngine.load(url: route.url, startSeconds: seconds, tracks: route.usesVLC ? startTracks : .none)
        if !wantsToPlay { newEngine.pause() }
    }

    // MARK: Controls

    func togglePlay() {
        guard let engine else { return }
        if isPlaying {
            wantsToPlay = false
            engine.pause()
            phase = .paused
        } else {
            wantsToPlay = true
            lastAdvanceAt = Date()
            engine.play()
            phase = .playing
        }
        report(.progress)
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), duration > 0 ? duration - 1 : seconds)
        engine?.seek(to: target)
        position = target
        lastAdvanceAt = Date()
        report(.progress)
    }

    func skip(_ delta: Double) { seek(to: position + delta) }

    func selectAudio(_ id: Int) {
        engine?.selectAudio(id)
        currentAudio = id
    }

    func selectSubtitle(_ id: Int?) {
        engine?.selectSubtitle(id)
        currentSubtitle = id
    }

    private func refreshTracks(force: Bool = false) {
        guard let engine, force || Date().timeIntervalSince(lastTrackRefresh) > 2 else { return }
        lastTrackRefresh = Date()
        let a = engine.audioTracks, s = engine.subtitleTracks
        if a != audioOptions { audioOptions = a }
        if s != subtitleOptions { subtitleOptions = s }
        let ca = engine.currentAudio, cs = engine.currentSubtitle
        if ca != currentAudio { currentAudio = ca }
        if cs != currentSubtitle { currentSubtitle = cs }
    }

    func retry() {
        reloadsInARow = 0
        wantsToPlay = true
        if routes.isEmpty {
            Task { await start() }
        } else {
            phase = .preparing
            open(at: position)
            startTicking()
        }
    }

    /// The app is going to the background: pause and make sure the position lands.
    func enterBackground() {
        guard !closed, engine != nil else { return }
        wantsToPlay = false
        engine?.pause()
        if phase == .playing || phase == .buffering { phase = .paused }
        let taskId = UIApplication.shared.beginBackgroundTask(withName: "progress")
        let report = makeReport(paused: true)
        let sync = sync
        let run = runTimeTicks
        Task {
            await sync.report(.progress, report, runTimeTicks: run)
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        tickTask?.cancel()
        tickTask = nil
        if engine != nil, startedReported || position > 0 {
            let report = makeReport(paused: true)
            let sync = sync
            let run = runTimeTicks
            // Runs on its own: the screen is already gone.
            Task { await sync.report(.stopped, report, runTimeTicks: run) }
        }
        engine?.stop()
        engine = nil
    }

    // MARK: Tick: state, stalls, reports

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let engine, !closed else { return }
        let status = engine.status
        let now = Date()
        let pos = engine.currentSeconds
        let dur = engine.durationSeconds
        if dur > 0 { duration = dur } else if let rt = runTimeTicks, duration == 0 { duration = Ticks.toSeconds(rt) }

        if !hasPlayedAnything, now.timeIntervalSince(routeOpenedAt) > Self.slowOpenNotice {
            openingMessage = "Il server ci sta mettendo un po'…"
        }

        if pos > 0, abs(pos - lastSeenPosition) > 0.2 {
            if lastSeenPosition >= 0, !hasPlayedAnything {
                hasPlayedAnything = true
                if openSeconds == nil { openSeconds = now.timeIntervalSince(tappedAt) }
            }
            lastSeenPosition = pos
            lastAdvanceAt = now
            position = pos
        }

        switch status {
        case .failed(let message):
            if !hasPlayedAnything {
                // This route cannot open the file: try the next one.
                routeIndex += 1
                if routeIndex < routes.count {
                    open(at: position)
                } else {
                    phase = .failed(message)
                    tickTask?.cancel()
                }
            } else {
                reload(reason: message)
            }
            return
        case .ended:
            phase = .ended
            position = duration
            report(.stopped)
            tickTask?.cancel()
            return
        default:
            break
        }

        if !startedReported, hasPlayedAnything {
            startedReported = true
            report(.start)
        }

        // Stall watchdog: we want to play, but time has not moved.
        if wantsToPlay {
            let limit = hasPlayedAnything ? Self.stallTimeout : Self.openTimeout
            if now.timeIntervalSince(lastAdvanceAt) > limit {
                if hasPlayedAnything {
                    reload(reason: "Il video si è bloccato.")
                } else {
                    // Never started: treat as a failed route.
                    routeIndex += 1
                    if routeIndex < routes.count {
                        open(at: position)
                    } else {
                        phase = .failed("Il server non risponde. Controlla la connessione e riprova.")
                        tickTask?.cancel()
                    }
                }
                return
            }
        }

        switch status {
        case .playing:
            phase = .playing
            if now.timeIntervalSince(smoothSince) > 60 { reloadsInARow = 0 }
        case .paused:
            phase = wantsToPlay ? .buffering : .paused
        case .buffering, .opening:
            phase = hasPlayedAnything ? .buffering : .preparing
            smoothSince = now
        default:
            break
        }

        if hasPlayedAnything { refreshTracks() }

        if hasPlayedAnything, now.timeIntervalSince(lastReportAt) >= Self.reportInterval {
            report(.progress)
        }
    }

    /// Reopens the same route at the same second. Fixes most network stalls.
    private func reload(reason: String) {
        reloadsInARow += 1
        guard reloadsInARow <= Self.maxReloads else {
            phase = .failed("\(reason) La connessione al server è instabile.")
            tickTask?.cancel()
            report(.progress)
            return
        }
        phase = .reconnecting
        smoothSince = Date()
        open(at: max(position - 2, 0))
    }

    // MARK: Reports

    private func makeReport(paused: Bool) -> PlaybackReport {
        PlaybackReport(
            itemId: item.id,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: Ticks.fromSeconds(position),
            isPaused: paused,
            playMethod: routeIndex < routes.count ? routes[routeIndex].playMethod : "DirectPlay"
        )
    }

    private func report(_ kind: ReportKind) {
        guard hasPlayedAnything || kind == .stopped else { return }
        lastReportAt = Date()
        let r = makeReport(paused: !wantsToPlay)
        let sync = sync
        let run = runTimeTicks
        Task { await sync.report(kind, r, runTimeTicks: run) }
    }
}
