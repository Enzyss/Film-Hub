import Foundation
import Observation
import JellyCore

/// S06/S07: everything a title page shows. All calls run at the same time:
/// on the user's server each takes ~0.3-0.7 s, so the page fills in under 1 s.
@MainActor
@Observable
final class DetailModel {
    private(set) var item: BaseItem
    private(set) var loadingDetail = true
    private(set) var errorMessage: String?

    // Films
    private(set) var versions: [BaseItem] = []
    var selectedVersionId: String?
    var choice: TrackChoice?

    // Series
    private(set) var seasons: [BaseItem] = []
    var selectedSeasonId: String?
    private(set) var episodes: [BaseItem] = []
    private(set) var loadingEpisodes = false
    private(set) var nextEpisode: BaseItem?

    private(set) var similar: [BaseItem] = []

    @ObservationIgnored private var prefetch: PlayRequest.Prefetched?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    init(item: BaseItem) {
        self.item = item
    }

    /// The version to play: the one picked, else the one opened.
    var selectedVersion: BaseItem {
        versions.first { $0.id == selectedVersionId } ?? item
    }

    var source: MediaSource? { selectedVersion.mediaSources?.first }

    var audioTracks: [MediaStream] { source.map(Tracks.audio) ?? [] }
    var subtitleTracks: [MediaStream] { source.map(Tracks.subtitles) ?? [] }

    func load(api: JellyfinAPI?, audio: AudioPreference, subtitles: SubtitlePreference) async {
        guard let api else { return }
        errorMessage = nil
        let id = item.id
        async let detail = api.detail(id: id)
        async let similarItems = api.similar(id: id)
        do {
            item = try await detail
            loadingDetail = false
        } catch is CancellationError {
            return
        } catch {
            loadingDetail = false
            errorMessage = error.localizedDescription
        }
        if item.isSeries {
            await loadSeries(api: api)
        } else if item.isMovie {
            versions = (try? await api.versions(of: item)) ?? [item]
            if !versions.contains(where: { $0.id == item.id }) { versions.insert(item, at: 0) }
            selectedVersionId = item.id
            resetChoice(audio: audio, subtitles: subtitles)
            startPrefetch(api: api)
        }
        similar = (try? await similarItems) ?? []
    }

    func resetChoice(audio: AudioPreference, subtitles: SubtitlePreference) {
        guard let source else { choice = nil; return }
        choice = Tracks.defaultChoice(for: source, audio: audio, subtitles: subtitles)
    }

    /// Asks the server how to play while the user reads the page.
    func startPrefetch(api: JellyfinAPI) {
        prefetchTask?.cancel()
        let version = selectedVersion
        let choice = choice
        let msid = source?.id
        prefetchTask = Task {
            let start = Ticks.fromSeconds(version.resumeSeconds)
            guard let info = try? await api.playbackInfo(itemId: version.id, startTicks: start,
                                                         mediaSourceId: msid, choice: choice),
                  !Task.isCancelled else { return }
            prefetch = PlayRequest.Prefetched(info: info, choice: choice, mediaSourceId: msid, at: Date())
        }
    }

    func prefetched() -> PlayRequest.Prefetched? {
        guard let p = prefetch, p.matches(choice: choice, mediaSourceId: source?.id) else { return nil }
        return p
    }

    // MARK: Series

    private func loadSeries(api: JellyfinAPI) async {
        let id = item.id
        async let seasonList = api.seasons(seriesId: id)
        async let next = api.nextUp(seriesId: id)
        seasons = (try? await seasonList) ?? []
        nextEpisode = try? await next
        // Open on the season of the next episode, else the first one.
        let target = seasons.first { $0.id == nextEpisode?.seasonId } ?? seasons.first
        if let target { await selectSeason(target.id, api: api) }
    }

    func selectSeason(_ id: String, api: JellyfinAPI?) async {
        guard let api else { return }
        selectedSeasonId = id
        loadingEpisodes = true
        defer { loadingEpisodes = false }
        let seriesId = item.id
        let list = (try? await api.episodes(seriesId: seriesId, seasonId: id)) ?? []
        if selectedSeasonId == id { episodes = list }
    }

    func setPlayed(_ played: Bool, api: JellyfinAPI?) async {
        guard let api else { return }
        try? await api.markPlayed(itemId: item.id, played: played)
        if let fresh = try? await api.detail(id: item.id) { item = fresh }
    }

    /// "Riprendi da 42:10", "Guarda S2 · E3" or "Riproduci".
    var playLabel: String {
        if item.isSeries {
            guard let ep = nextEpisode else { return "Riproduci" }
            let label = ep.episodeLabel ?? ""
            return ep.resumeSeconds > 0 ? "Riprendi \(label)" : "Guarda \(label)"
        }
        let s = selectedVersion.resumeSeconds
        return s > 0 ? "Riprendi da \(Ticks.clock(s))" : "Riproduci"
    }
}
