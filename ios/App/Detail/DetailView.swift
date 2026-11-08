import SwiftUI
import JellyCore

struct DetailView: View {
    @Environment(AppModel.self) private var app
    @State private var model: DetailModel
    @State private var overviewExpanded = false

    init(item: BaseItem) {
        _model = State(initialValue: DetailModel(item: item))
    }

    private var item: BaseItem { model.item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    actions
                    if item.isMovie { trackPickers }
                    overview
                    if let error = model.errorMessage {
                        ErrorBanner(message: error) { Task { await reload() } }
                            .padding(.horizontal, -Theme.Space.l)
                    }
                }
                .padding(.horizontal, Theme.Space.l)

                if item.isSeries { seriesSection }
                cast
                if !model.similar.isEmpty {
                    ItemRow(title: "Titoli simili", items: model.similar, api: app.api)
                }
            }
            .padding(.bottom, Theme.Space.xxl)
            // Never wider than the screen, whatever a child asks for.
            .containerRelativeFrame(.horizontal, alignment: .leading)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.Colors.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await reload() }
        .onChange(of: app.homeRefreshToken) { _, _ in
            // Back from the player: refresh the position and the next episode.
            Task { await reload() }
        }
    }

    private func reload() async {
        await model.load(api: app.api, audio: app.audioPreference, subtitles: app.subtitlePreference)
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: item.backdropURL(api: app.api, width: 1280))
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .clipped()
            LinearGradient(colors: [.clear, Theme.Colors.background],
                           startPoint: .center, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: Theme.Space.m) {
                RemoteImage(url: item.posterURL(api: app.api, width: 240))
                    .frame(width: 100, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .shadow(radius: 8)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(item.name ?? "")
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(3)
                    Text(item.metaLine)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    RatingBadges(item: item)
                    if let genres = item.genres, !genres.isEmpty {
                        Text(genres.prefix(3).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.l)
        }
    }

    // MARK: Play and actions

    private var actions: some View {
        VStack(spacing: Theme.Space.m) {
            Button(action: play) {
                Label(model.playLabel, systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.loadingDetail && item.isSeries)

            if item.isMovie, model.selectedVersion.resumeSeconds > 0 {
                Button {
                    var start = model.selectedVersion
                    start.userData?.playbackPositionTicks = 0
                    app.play(start, source: model.source, choice: model.choice)
                } label: {
                    Label("Dall'inizio", systemImage: "backward.end.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.Colors.textPrimary)
            }

            HStack(spacing: Theme.Space.m) {
                if model.versions.count > 1 {
                    Menu {
                        Picker("Versione", selection: Binding(
                            get: { model.selectedVersionId ?? item.id },
                            set: { id in
                                if item.isSeries {
                                    guard let v = model.versions.first(where: { $0.id == id }) else { return }
                                    Task {
                                        await model.switchSeries(to: v, api: app.api, audio: app.audioPreference,
                                                                 subtitles: app.subtitlePreference)
                                    }
                                    return
                                }
                                model.selectedVersionId = id
                                model.resetChoice(audio: app.audioPreference, subtitles: app.subtitlePreference)
                                if let api = app.api { model.startPrefetch(api: api) }
                            })) {
                            ForEach(model.versions) { v in
                                Text(versionLabel(v)).tag(v.id)
                            }
                        }
                    } label: {
                        Label(versionLabel(model.selectedVersion), systemImage: "rectangle.stack")
                            .font(.footnote.weight(.semibold))
                    }
                }
                Spacer()
                Button {
                    Task { await model.setPlayed(!item.isPlayed, api: app.api) }
                } label: {
                    Label(item.isPlayed ? "Visto" : "Segna come visto",
                          systemImage: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.footnote.weight(.semibold))
                }
            }
            .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private func play() {
        if item.isSeries {
            if let ep = model.nextEpisode ?? model.episodes.first { app.play(ep) }
            return
        }
        app.play(model.selectedVersion, source: model.source, choice: model.choice,
                 prefetched: model.prefetched())
    }

    /// "4K · Dolby Vision", "1080p", "720p"; for series "Doppiato ITA", "Sub ITA".
    private func versionLabel(_ v: BaseItem) -> String {
        if v.isSeries { return v.versionLabel ?? "Versione" }
        guard let video = v.mediaSources?.first?.videoStream else { return "Versione" }
        let h = video.height ?? 0
        let res = h >= 2000 ? "4K" : h >= 1000 ? "1080p" : h >= 700 ? "720p" : h > 0 ? "\(h)p" : "Video"
        let range = video.videoRangeType ?? "SDR"
        if range.contains("DOVI") { return "\(res) · Dolby Vision" }
        if range.contains("HDR") { return "\(res) · HDR" }
        return res
    }

    // MARK: Tracks

    @ViewBuilder
    private var trackPickers: some View {
        if model.audioTracks.count > 1 || !model.subtitleTracks.isEmpty {
            HStack(spacing: Theme.Space.m) {
                if model.audioTracks.count > 1 {
                    Menu {
                        Picker("Audio", selection: Binding(
                            get: { model.choice?.audioIndex ?? -1 },
                            set: { idx in
                                model.choice = TrackChoice(audioIndex: idx, subtitleIndex: model.choice?.subtitleIndex)
                                if let api = app.api { model.startPrefetch(api: api) }
                            })) {
                            ForEach(model.audioTracks, id: \.index) { s in
                                Text(Tracks.label(s)).tag(s.index ?? -1)
                            }
                        }
                    } label: {
                        trackChip(icon: "speaker.wave.2.fill",
                                  text: model.audioTracks.first { $0.index == model.choice?.audioIndex }.map(Tracks.label) ?? "Audio")
                    }
                }
                if !model.subtitleTracks.isEmpty {
                    Menu {
                        Picker("Sottotitoli", selection: Binding(
                            get: { model.choice?.subtitleIndex ?? -1 },
                            set: { idx in
                                model.choice = TrackChoice(audioIndex: model.choice?.audioIndex,
                                                           subtitleIndex: idx < 0 ? nil : idx)
                                if let api = app.api { model.startPrefetch(api: api) }
                            })) {
                            Text("Nessuno").tag(-1)
                            ForEach(model.subtitleTracks, id: \.index) { s in
                                Text(Tracks.label(s)).tag(s.index ?? -1)
                            }
                        }
                    } label: {
                        trackChip(icon: "captions.bubble.fill",
                                  text: model.subtitleTracks.first { $0.index == model.choice?.subtitleIndex }.map(Tracks.label) ?? "Nessuno")
                    }
                }
            }
        }
    }

    private func trackChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.Colors.surface)
            .clipShape(Capsule())
            .foregroundStyle(Theme.Colors.textPrimary)
    }

    // MARK: Overview

    @ViewBuilder
    private var overview: some View {
        if let tagline = item.taglines?.first, !tagline.isEmpty {
            Text(tagline)
                .font(.subheadline.italic())
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        if let text = item.overview, !text.isEmpty {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(overviewExpanded ? nil : 4)
                .onTapGesture { withAnimation { overviewExpanded.toggle() } }
        } else if model.loadingDetail {
            RoundedRectangle(cornerRadius: 4).fill(Theme.Colors.surface).frame(height: 60)
        }
        if let studios = item.studios?.compactMap(\.name), !studios.isEmpty {
            Text(studios.prefix(3).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    // MARK: Series

    @ViewBuilder
    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if model.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(model.seasons) { season in
                            let selected = season.id == model.selectedSeasonId
                            Button {
                                Task { await model.selectSeason(season.id, api: app.api) }
                            } label: {
                                Text(season.name ?? "Stagione")
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, Theme.Space.m)
                                    .padding(.vertical, Theme.Space.s)
                                    .background(selected ? Theme.Colors.accent : Theme.Colors.surface)
                                    .foregroundStyle(selected ? Color.black : Theme.Colors.textPrimary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.l)
                }
            } else if let only = model.seasons.first {
                Text(only.name ?? "Episodi")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .padding(.horizontal, Theme.Space.l)
            }

            if model.loadingEpisodes && model.episodes.isEmpty {
                ProgressView().tint(Theme.Colors.accent).frame(maxWidth: .infinity).padding()
            }
            LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(model.episodes) { ep in
                    Button { app.play(ep) } label: {
                        EpisodeRow(episode: ep, api: app.api, isNext: ep.id == model.nextEpisode?.id)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.l)
        }
    }

    // MARK: Cast

    @ViewBuilder
    private var cast: some View {
        let people = (item.people ?? []).filter { $0.type == "Actor" || $0.type == "Director" }.prefix(20)
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                RowHeader(title: "Cast", showsMore: false)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        ForEach(Array(people)) { p in
                            VStack(spacing: Theme.Space.xs) {
                                RemoteImage(url: app.api?.personImageURL(p, width: 160))
                                    .frame(width: Theme.Size.castPhoto, height: Theme.Size.castPhoto)
                                    .clipShape(Circle())
                                Text(p.name ?? "")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                Text(p.type == "Director" ? "Regia" : (p.role ?? ""))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(width: Theme.Size.castPhoto + 16)
                        }
                    }
                    .padding(.horizontal, Theme.Space.l)
                }
            }
        }
    }
}

struct EpisodeRow: View {
    let episode: BaseItem
    let api: JellyfinAPI?
    let isNext: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: episode.landscapeImageURL(api: api, width: 360))
                    .frame(width: 150, height: 84)
                    .clipped()
                if let p = episode.progress, !episode.isPlayed { ProgressBar(value: p) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(alignment: .center) {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.85))
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    Text("\(episode.indexNumber.map(String.init) ?? "–"). \(episode.name ?? "")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)
                    if episode.isPlayed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.accent)
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    if let rt = episode.runTimeTicks { Text(Ticks.duration(rt)) }
                    if isNext {
                        Text("Prossimo")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.Colors.accent)
                            .foregroundStyle(Color.black)
                            .clipShape(Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                if let o = episode.overview, !o.isEmpty {
                    Text(o)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
