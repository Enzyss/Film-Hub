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

    /// The episode or film playing. Changes when the next episode starts.
    private(set) var item: BaseItem
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

    // Next episode
    private(set) var upNext: BaseItem?
    /// Seconds left when the "next episode" card shows, nil when hidden.
    private(set) var upNextCountdown: Int?
    @ObservationIgnored private var upNextDismissed = false
    @ObservationIgnored private var upNextLookup: Task<Void, Never>?
    @ObservationIgnored private var upNextLastTry = Date.distantPast
    /// The series has no episode after this one (checked with the server).
    @ObservationIgnored private var upNextNone = false
    @ObservationIgnored private var endLookupStarted = false
    /// Show the card this long before the end (the server has no credits markers).
    static let upNextLead: Double = 30

    // Handover VLC -> Apple player, for Picture in Picture. Measured on the
    // user's phone: opening through the server first made films take 20-30 s.
    // Now VLC starts at once; after a while the Apple player prepares the same
    // film silently and takes over at the same second.
    @ObservationIgnored private var handoffURL: URL?
    @ObservationIgnored private var handoffChoice: TrackChoice?
    @ObservationIgnored private var handoffEngine: AppleEngine?
    @ObservationIgnored private var handoffTarget: Double = 0
    @ObservationIgnored private var handoffStartedAt = Date()
    @ObservationIgnored private var handoffAttempts = 0
    @ObservationIgnored private var handoffTask: Task<Void, Never>?
    /// Smooth VLC playback before the Apple player starts preparing.
    static let handoffDelay: TimeInterval = 10
    /// How far ahead of VLC the Apple player prepares (the server needs a few
    /// seconds to start the stream at a new point).
    static let handoffLead: Double = 20
    static let handoffMaxAttempts = 3

    // Picture in Picture
    private(set) var isPiPActive = false
    /// A short message over the video ("Picture in Picture non disponibile…").
    private(set) var notice: String?
    /// Set by AppModel: what happens to the screen when PiP starts, is
    /// restored, or is closed from its own window.
    @ObservationIgnored var onPiPStarted: (() -> Void)?
    @ObservationIgnored var onPiPRestore: (() -> Void)?
    @ObservationIgnored var onPiPClosed: (() -> Void)?
    @ObservationIgnored private var pendingPiP = false
    @ObservationIgnored private var pendingPiPTicks = 0
    @ObservationIgnored private var restoringFromPiP = false
    /// True once start() has run: a reopened screen reuses the running model.
    @ObservationIgnored private(set) var started = false

    @ObservationIgnored private let api: JellyfinAPI
    @ObservationIgnored private let sync: ProgressSync
    @ObservationIgnored private let preference: PlayerPreference
    let request: PlayRequest
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
    /// After this long, tell the user we are still working on it. Opening takes
    /// 3-6 s on the user's server, more on mobile data.
    static let slowOpenNotice: TimeInterval = 9
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
        guard !started else { return }
        started = true
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
        // The title page's version and tracks apply to the film it opened, not
        // to the episodes that follow.
        let isFirst = item.id == request.item.id
        let wantedSource = isFirst ? request.source?.id : nil
        let requestedChoice = isFirst ? request.choice : nil
        do {
            let info: PlaybackInfoResponse
            if let pre = request.prefetched, item.id == request.item.id,
               pre.matches(choice: request.choice, mediaSourceId: wantedSource) {
                info = pre.info  // fetched while the title page was open
            } else {
                info = try await api.playbackInfo(itemId: item.id, startTicks: Ticks.fromSeconds(startSeconds),
                                                  mediaSourceId: wantedSource, choice: requestedChoice)
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

        let choice = requestedChoice
            ?? Tracks.defaultChoice(for: source, audio: audioPreference, subtitles: subtitlePreference)
        startTracks = makeStartTracks(choice: choice, source: source)

        let quick = PlaybackDecider.isRepackagedQuickly(source)
        let subtitlesOn = choice.subtitleIndex != nil
        cancelHandoff()
        handoffAttempts = 0
        handoffURL = nil
        handoffChoice = nil
        if preference == .automatic, quick, !subtitlesOn,
           !PlaybackDecider.isAppleCompatible(source),
           let t = api.transcodeURL(source.transcodingUrl) {
            handoffURL = t
            // The server's stream must carry the chosen audio (Italian, say):
            // fetched later, while the film already plays.
            if choice.audioIndex != source.defaultAudioStream?.index, requestedChoice == nil {
                handoffChoice = choice
            }
        }

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
            needsTrackControl: Tracks.needsTrackControl(choice, source: source),
            subtitlesOn: subtitlesOn
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
        let newEngine: any PlaybackEngine
        if let current = engine, (current is VLCEngine) == route.usesVLC {
            // Same kind of player: load the new stream in it. Keeps Picture in
            // Picture open when the next episode starts.
            newEngine = current
        } else {
            engine?.stop()
            newEngine = route.usesVLC ? VLCEngine() : AppleEngine()
        }
        engine = newEngine
        routeLabel = route.label
        openingMessage = routeIndex == 0 ? "Apertura…" : "Provo un altro modo (\(route.label))…"
        hasPlayedAnything = false
        lastSeenPosition = -1
        lastAdvanceAt = Date()
        routeOpenedAt = Date()
        newEngine.onPiP = { [weak self] event in self?.handlePiP(event) }
        newEngine.load(url: route.url, startSeconds: seconds, tracks: route.usesVLC ? startTracks : .none)
        if !wantsToPlay { newEngine.pause() }
    }

    // MARK: Controls

    func togglePlay() {
        guard let engine else { return }
        if isPlaying {
            wantsToPlay = false
            engine.pause()
            cancelHandoff()
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
        cancelHandoff()
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

    /// The app is going to the background: pause (unless PiP takes over) and
    /// make sure the position lands.
    func enterBackground() {
        guard !closed, engine != nil else { return }
        // The Apple player turns into PiP by itself when playing: keep going.
        let pipTakesOver = engine?.supportsPiP == true && (isPlaying || isPiPActive)
        if !pipTakesOver {
            wantsToPlay = false
            engine?.pause()
            if phase == .playing || phase == .buffering { phase = .paused }
        }
        let taskId = UIApplication.shared.beginBackgroundTask(withName: "progress")
        let report = makeReport(paused: true)
        let sync = sync
        let run = runTimeTicks
        Task {
            await sync.report(.progress, report, runTimeTicks: run)
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }

    // MARK: Next episode

    /// Asks the server for the episode after this one. Retried every 20 s
    /// until it answers (a failed request used to leave the card off for the
    /// whole episode, and the player closed at the end).
    private func findNextEpisode() {
        guard item.isEpisode, upNext == nil, !upNextNone, upNextLookup == nil else { return }
        upNextLastTry = Date()
        let current = item
        let api = api
        upNextLookup = Task { [weak self] in
            let result: BaseItem??
            do { result = .some(try await api.nextEpisode(after: current)) } catch { result = nil }
            guard let self else { return }
            self.upNextLookup = nil
            guard self.item.id == current.id, let answer = result else { return }
            if let next = answer { self.upNext = next } else { self.upNextNone = true }
        }
    }

    /// Shows the card in the last 30 seconds; at zero, the next episode starts.
    private func updateUpNext() {
        guard let next = upNext, !upNextDismissed, duration > Self.upNextLead * 3 else {
            if upNextCountdown != nil { upNextCountdown = nil }
            return
        }
        let left = duration - position
        if left <= Self.upNextLead {
            let secs = max(Int(left.rounded(.up)), 0)
            if upNextCountdown != secs { upNextCountdown = secs }
            if left <= 0.8 { playNext(next) }
        } else if upNextCountdown != nil {
            upNextCountdown = nil  // seeked back
        }
    }

    func playUpNextNow() {
        guard let next = upNext else { return }
        playNext(next)
    }

    func dismissUpNext() {
        upNextDismissed = true
        upNextCountdown = nil
    }

    /// Ends this episode (it counts as watched) and starts the next one in the
    /// same player.
    private func playNext(_ next: BaseItem) {
        guard !closed else { return }
        position = max(position, duration)
        let finished = makeReport(paused: false)
        let sync = sync
        let run = runTimeTicks
        Task { await sync.report(.stopped, finished, runTimeTicks: run) }

        cancelHandoff()
        item = next
        upNext = nil
        upNextCountdown = nil
        upNextDismissed = false
        upNextNone = false
        upNextLookup?.cancel()
        upNextLookup = nil
        upNextLastTry = .distantPast
        endLookupStarted = false
        routes = []
        routeIndex = 0
        playSessionId = nil
        mediaSourceId = nil
        runTimeTicks = next.runTimeTicks
        startedReported = false
        hasPlayedAnything = false
        openSeconds = nil
        reloadsInARow = 0
        wantsToPlay = true
        duration = 0
        position = next.resumeSeconds
        phase = .preparing
        openingMessage = "Prossimo episodio…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareRoutes(startSeconds: self.position)
                guard !self.closed, self.item.id == next.id else { return }
                // In PiP the next episode stays on the Apple player, or the
                // PiP window would close.
                if self.isPiPActive, self.engine is AppleEngine,
                   let i = self.routes.firstIndex(where: { !$0.usesVLC }) {
                    let r = self.routes.remove(at: i)
                    self.routes.insert(r, at: 0)
                    self.handoffURL = nil
                }
                self.open(at: self.position)
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Picture in Picture

    /// True when PiP can work for this film: the Apple player now, or a switch
    /// to the server's HLS stream for files only VLC opens (MKV and the rest).
    var canPiP: Bool {
        if engine?.supportsPiP == true { return true }
        return routes.contains { !$0.usesVLC } && AppleEngine.isPiPSupportedOnDevice
    }

    func requestPiP() {
        if isPiPActive { engine?.stopPiP(); return }
        if engine?.supportsPiP == true {
            pendingPiP = true
            pendingPiPTicks = 0
            return
        }
        // On VLC with a handover possible: finish it now, or as soon as the
        // Apple player is ready, then open PiP.
        if handoffURL != nil {
            pendingPiP = true
            pendingPiPTicks = 0
            if let h = handoffEngine, h.isPrepared {
                completeHandoff()
            } else {
                if handoffEngine == nil { armHandoff(lead: 12) }
                show(notice: "Picture in Picture disponibile tra pochi secondi…")
            }
            return
        }
        // Otherwise: reopen the same second with the Apple player on the
        // server's stream (slower: the server prepares it from scratch).
        guard let idx = routes.firstIndex(where: { !$0.usesVLC }) else {
            show(notice: "Picture in Picture non disponibile per questo file.")
            return
        }
        routeIndex = idx
        pendingPiP = true
        pendingPiPTicks = 0
        wantsToPlay = true
        phase = .preparing
        open(at: position)
        openingMessage = "Preparo il Picture in Picture…"
    }

    // MARK: Handover

    private var handoffPossible: Bool {
        handoffURL != nil && engine is VLCEngine && !closed && handoffAttempts < Self.handoffMaxAttempts
    }

    private func updateHandoff(now: Date) {
        guard handoffPossible else { return }
        guard let h = handoffEngine else {
            // Start preparing after 10 s of smooth playback.
            if hasPlayedAnything, wantsToPlay, phase == .playing,
               now.timeIntervalSince(smoothSince) >= Self.handoffDelay {
                armHandoff(lead: Self.handoffLead)
            }
            return
        }
        if h.preparationFailed || now.timeIntervalSince(handoffStartedAt) > 60 {
            cancelHandoff()
            handoffAttempts += 1
            return
        }
        let prepared = h.isPrepared
        if position >= handoffTarget - 0.25 {
            if prepared {
                completeHandoff()
            } else {
                // VLC got there first: try again further ahead.
                cancelHandoff()
                handoffAttempts += 1
            }
        } else if prepared, pendingPiP {
            completeHandoff()  // PiP asked for: no need to wait for the mark
        }
    }

    private func armHandoff(lead: Double) {
        guard let url = handoffURL, handoffEngine == nil else { return }
        let target = position + lead
        handoffTarget = target
        handoffStartedAt = Date()
        let choice = handoffChoice
        let itemId = item.id
        let msid = mediaSourceId
        let api = api
        handoffTask?.cancel()
        handoffTask = Task { [weak self] in
            var streamURL = url
            if let choice,
               let info = try? await api.playbackInfo(itemId: itemId, startTicks: Ticks.fromSeconds(target),
                                                      mediaSourceId: msid, choice: choice),
               let fresh = api.transcodeURL(info.mediaSources?.first(where: { $0.id == msid })?.transcodingUrl
                                            ?? info.mediaSources?.first?.transcodingUrl) {
                streamURL = fresh
            }
            guard let self, !Task.isCancelled, self.item.id == itemId, !self.closed else { return }
            let e = AppleEngine()
            e.prepare(url: streamURL, startSeconds: target)
            self.handoffEngine = e
        }
    }

    private func cancelHandoff() {
        handoffTask?.cancel()
        handoffTask = nil
        handoffEngine?.stop()
        handoffEngine = nil
    }

    /// The Apple player takes over at VLC's current second.
    private func completeHandoff() {
        guard let apple = handoffEngine, let old = engine else { return }
        handoffEngine = nil
        handoffTask = nil
        let at = max(position, old.currentSeconds)
        apple.onPiP = { [weak self] event in self?.handlePiP(event) }
        apple.startPrepared(at: at)
        engine = apple
        old.stop()
        if let idx = routes.firstIndex(where: { !$0.usesVLC }) { routeIndex = idx }
        routeLabel = routes.indices.contains(routeIndex) ? routes[routeIndex].label : routeLabel
        lastSeenPosition = at
        lastAdvanceAt = Date()
        smoothSince = Date()
        handoffURL = nil
        audioOptions = []
        subtitleOptions = []
    }

    private func handlePiP(_ event: PiPEvent) {
        switch event {
        case .started:
            isPiPActive = true
            pendingPiP = false
            onPiPStarted?()
        case .restore:
            restoringFromPiP = true
            onPiPRestore?()
        case .stopped:
            isPiPActive = false
            if restoringFromPiP {
                restoringFromPiP = false
            } else {
                // Closed from the PiP window: the film ends here.
                onPiPClosed?()
            }
        case .failed(let message):
            pendingPiP = false
            show(notice: "Picture in Picture non riuscito: \(message)")
        }
    }

    private func show(notice text: String) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.notice == text { self?.notice = nil }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        cancelHandoff()
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
        // Between episodes the old stream is still loaded: wait for the new one.
        guard let engine, !closed, !routes.isEmpty else { return }
        let status = engine.status
        let now = Date()
        let pos = engine.currentSeconds
        let dur = engine.durationSeconds
        if dur > 0 { duration = dur } else if let rt = runTimeTicks, duration == 0 { duration = Ticks.toSeconds(rt) }

        if !hasPlayedAnything, now.timeIntervalSince(routeOpenedAt) > Self.slowOpenNotice {
            openingMessage = "Ancora un attimo…"
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
            position = duration
            if let next = upNext, !upNextDismissed {
                playNext(next)
                return
            }
            // An episode whose next one is not known yet: ask now, then go on.
            if item.isEpisode, !upNextDismissed, !upNextNone, !endLookupStarted {
                endLookupStarted = true
                phase = .preparing
                openingMessage = "Prossimo episodio…"
                let current = item
                let api = api
                Task { [weak self] in
                    let next = try? await api.nextEpisode(after: current)
                    guard let self, !self.closed, self.item.id == current.id else { return }
                    if let next {
                        self.playNext(next)
                    } else {
                        self.phase = .ended
                        self.report(.stopped)
                        self.tickTask?.cancel()
                    }
                }
                return
            }
            if endLookupStarted { return }  // waiting for the answer
            phase = .ended
            report(.stopped)
            tickTask?.cancel()
            return
        default:
            break
        }

        if !startedReported, hasPlayedAnything {
            startedReported = true
            report(.start)
            findNextEpisode()
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
            // Play pressed outside our controls (PiP window, lock screen).
            if hasPlayedAnything { wantsToPlay = true }
            if now.timeIntervalSince(smoothSince) > 60 { reloadsInARow = 0 }
        case .paused:
            if hasPlayedAnything {
                // Paused outside our controls (PiP window): not a stall.
                if wantsToPlay { wantsToPlay = false; report(.progress) }
                phase = .paused
            } else {
                phase = wantsToPlay ? .buffering : .paused
            }
        case .buffering, .opening:
            phase = hasPlayedAnything ? .buffering : .preparing
            smoothSince = now
        default:
            break
        }

        if hasPlayedAnything { refreshTracks() }
        if hasPlayedAnything, item.isEpisode, upNext == nil, !upNextNone,
           now.timeIntervalSince(upNextLastTry) > 20 {
            findNextEpisode()
        }
        updateUpNext()
        updateHandoff(now: now)

        // PiP asked for: start it as soon as the Apple player is ready.
        if pendingPiP, hasPlayedAnything, engine.supportsPiP {
            if engine.startPiP() {
                pendingPiP = false
            } else {
                pendingPiPTicks += 1
                if pendingPiPTicks > 20 {  // ~10 s
                    pendingPiP = false
                    show(notice: "Picture in Picture non disponibile in questo momento.")
                }
            }
        }

        if hasPlayedAnything, now.timeIntervalSince(lastReportAt) >= Self.reportInterval {
            report(.progress)
        }
    }

    /// Reopens the same route at the same second. Fixes most network stalls.
    private func reload(reason: String) {
        cancelHandoff()
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
