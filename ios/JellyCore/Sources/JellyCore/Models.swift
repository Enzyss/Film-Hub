import Foundation

public struct PublicSystemInfo: Codable, Hashable, Sendable {
    public var serverName: String?
    public var version: String?
    public var id: String?
    public var productName: String?
}

public struct UserDto: Codable, Hashable, Sendable {
    public var id: String
    public var name: String?
}

public struct AuthenticationResult: Codable, Hashable, Sendable {
    public var accessToken: String?
    public var serverId: String?
    public var user: UserDto?
}

public struct QueryResult<T: Codable & Sendable>: Codable, Sendable {
    public var items: [T]?
    public var totalRecordCount: Int?
}

public struct UserData: Codable, Hashable, Sendable {
    public var playbackPositionTicks: Int64?
    public var playedPercentage: Double?
    public var played: Bool?
    public var isFavorite: Bool?
    public var lastPlayedDate: String?
}

public struct MediaStream: Codable, Hashable, Sendable {
    public var type: String?
    public var codec: String?
    public var codecTag: String?
    public var index: Int?
    public var language: String?
    public var displayTitle: String?
    public var title: String?
    public var isDefault: Bool?
    public var isExternal: Bool?
    public var isTextSubtitleStream: Bool?
    public var channels: Int?
    public var isForced: Bool?
    public var height: Int?
    public var videoRangeType: String?
}

public struct MediaSource: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String?
    public var container: String?
    public var runTimeTicks: Int64?
    public var bitrate: Int?
    public var eTag: String?
    public var supportsDirectPlay: Bool?
    public var supportsDirectStream: Bool?
    public var supportsTranscoding: Bool?
    public var transcodingUrl: String?
    public var defaultAudioStreamIndex: Int?
    public var defaultSubtitleStreamIndex: Int?
    public var mediaStreams: [MediaStream]?

    public init(
        id: String? = nil, container: String? = nil, supportsDirectPlay: Bool? = nil,
        transcodingUrl: String? = nil, defaultAudioStreamIndex: Int? = nil,
        mediaStreams: [MediaStream]? = nil
    ) {
        self.id = id
        self.container = container
        self.supportsDirectPlay = supportsDirectPlay
        self.transcodingUrl = transcodingUrl
        self.defaultAudioStreamIndex = defaultAudioStreamIndex
        self.mediaStreams = mediaStreams
    }

    public var videoStream: MediaStream? {
        mediaStreams?.first { $0.type == "Video" }
    }

    /// The audio track the server would pick: the default index, else the first.
    public var defaultAudioStream: MediaStream? {
        let audio = mediaStreams?.filter { $0.type == "Audio" } ?? []
        if let idx = defaultAudioStreamIndex, let s = audio.first(where: { $0.index == idx }) {
            return s
        }
        return audio.first
    }
}

public struct PlaybackInfoResponse: Codable, Sendable {
    public var mediaSources: [MediaSource]?
    public var playSessionId: String?
    public var errorCode: String?
}

public struct BaseItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var type: String?
    public var overview: String?
    public var productionYear: Int?
    public var runTimeTicks: Int64?
    public var communityRating: Double?
    public var officialRating: String?
    public var seriesId: String?
    public var seriesName: String?
    public var seasonId: String?
    public var indexNumber: Int?
    public var parentIndexNumber: Int?
    public var imageTags: [String: String]?
    public var backdropImageTags: [String]?
    public var parentBackdropItemId: String?
    public var parentBackdropImageTags: [String]?
    public var parentThumbItemId: String?
    public var parentThumbImageTag: String?
    public var seriesPrimaryImageTag: String?
    public var collectionType: String?
    public var userData: UserData?
    public var mediaSources: [MediaSource]?
    public var criticRating: Double?
    public var genres: [String]?
    public var studios: [NameId]?
    public var people: [Person]?
    public var providerIds: [String: String]?
    public var taglines: [String]?
    public var childCount: Int?
    public var endDate: String?
    public var status: String?

    public init(id: String, name: String? = nil, type: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
    }

    public var isSeries: Bool { type == "Series" }
    public var isMovie: Bool { type == "Movie" }

    /// Provider id by name ("Tmdb", "Imdb"). Checks both casings, see imageTag.
    public func providerId(_ name: String) -> String? {
        providerIds?[name] ?? providerIds?[JellyfinCoding.lowerFirst(name)]
    }

    /// Identifies the same film across libraries (HD and 4K copies).
    public var dedupeKey: String {
        if let t = providerId("Tmdb"), !t.isEmpty { return "tmdb:\(type ?? ""):\(t)" }
        if let i = providerId("Imdb"), !i.isEmpty { return "imdb:\(i)" }
        return "name:\(type ?? ""):\((name ?? "").lowercased()):\(productionYear ?? 0)"
    }

    /// "★ 7.8" from the audience score, if any.
    public var ratingLabel: String? {
        guard let r = communityRating, r > 0 else { return nil }
        return String(format: "★ %.1f", r)
    }

    /// "92%" from the critics' score, if any.
    public var criticLabel: String? {
        guard let c = criticRating, c > 0 else { return nil }
        return "\(Int(c.rounded()))%"
    }

    public var isPlayed: Bool { userData?.played == true }

    /// "2008 · 5 stagioni" or "1999 · 2 h 16 min".
    public var metaLine: String {
        var parts: [String] = []
        if let y = productionYear { parts.append(String(y)) }
        if isSeries, let n = childCount, n > 0 { parts.append(n == 1 ? "1 stagione" : "\(n) stagioni") }
        if !isSeries, let rt = runTimeTicks, rt > 0 { parts.append(Ticks.duration(rt)) }
        if let r = officialRating, !r.isEmpty { parts.append(r) }
        return parts.joined(separator: " · ")
    }

    public var isEpisode: Bool { type == "Episode" }

    /// "S2 · E5" for episodes.
    public var episodeLabel: String? {
        guard isEpisode else { return nil }
        let s = parentIndexNumber.map { "S\($0)" }
        let e = indexNumber.map { "E\($0)" }
        let parts = [s, e].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Main title for a card: the series name for episodes, else the item name.
    public var displayTitle: String {
        if isEpisode, let s = seriesName, !s.isEmpty { return s }
        return name ?? ""
    }

    /// Second line for a card: "S2 · E5 · Title" for episodes, else the year.
    public var displaySubtitle: String? {
        if isEpisode {
            return [episodeLabel, name].compactMap { $0 }.joined(separator: " · ")
        }
        return productionYear.map(String.init)
    }

    /// Seconds to resume from, or 0 to start from the beginning.
    public var resumeSeconds: Double {
        guard userData?.played != true,
              let ticks = userData?.playbackPositionTicks, ticks > 0 else { return 0 }
        return Ticks.toSeconds(ticks)
    }

    /// 0...1 progress for the bar on a card.
    public var progress: Double? {
        if let pct = userData?.playedPercentage, pct > 0 { return min(pct / 100, 1) }
        if let pos = userData?.playbackPositionTicks, let run = runTimeTicks, run > 0, pos > 0 {
            return min(Double(pos) / Double(run), 1)
        }
        return nil
    }

    /// Image tag by type. Looks up both "Primary" and "primary": JSONDecoder
    /// applies key strategies to dictionary keys as well.
    public func imageTag(_ type: String) -> String? {
        imageTags?[type] ?? imageTags?[JellyfinCoding.lowerFirst(type)]
    }
}

public struct NameId: Codable, Hashable, Sendable {
    public var name: String?
    public var id: String?
}

public struct Person: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var role: String?
    public var type: String?
    public var primaryImageTag: String?
}

extension Array where Element == BaseItem {
    /// One card per film: the first copy wins (HD and 4K libraries hold both).
    public func deduplicated() -> [BaseItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.dedupeKey).inserted }
    }
}
