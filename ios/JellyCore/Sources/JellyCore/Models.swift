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

    public init(id: String, name: String? = nil, type: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
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
