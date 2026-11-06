import Foundation

/// Which audio and subtitle tracks to play, by Jellyfin stream index.
public struct TrackChoice: Equatable, Hashable, Codable, Sendable {
    public var audioIndex: Int?
    /// nil = subtitles off.
    public var subtitleIndex: Int?

    public init(audioIndex: Int?, subtitleIndex: Int?) {
        self.audioIndex = audioIndex
        self.subtitleIndex = subtitleIndex
    }
}

public enum SubtitlePreference: String, CaseIterable, Codable, Sendable {
    case off, italian, english

    public var label: String {
        switch self {
        case .off: return "Nessuno"
        case .italian: return "Italiano"
        case .english: return "Inglese"
        }
    }

    var codes: [String] {
        switch self {
        case .off: return []
        case .italian: return ["ita", "it"]
        case .english: return ["eng", "en"]
        }
    }
}

public enum AudioPreference: String, CaseIterable, Codable, Sendable {
    case italian, english, original

    public var label: String {
        switch self {
        case .italian: return "Italiano"
        case .english: return "Inglese"
        case .original: return "Originale del file"
        }
    }

    var codes: [String] {
        switch self {
        case .italian: return ["ita", "it"]
        case .english: return ["eng", "en"]
        case .original: return []
        }
    }
}

public enum Tracks {
    public static func audio(_ source: MediaSource) -> [MediaStream] {
        (source.mediaStreams ?? []).filter { $0.type == "Audio" }
    }

    public static func subtitles(_ source: MediaSource) -> [MediaStream] {
        (source.mediaStreams ?? []).filter { $0.type == "Subtitle" }
    }

    /// The choice from the user's language preferences.
    public static func defaultChoice(for source: MediaSource, audio: AudioPreference,
                                     subtitles: SubtitlePreference) -> TrackChoice {
        let audioTracks = Self.audio(source)
        var audioIndex = source.defaultAudioStream?.index
        if let match = audioTracks.first(where: { matches($0, audio.codes) }) {
            audioIndex = match.index
        }
        var subIndex: Int?
        let subs = Self.subtitles(source)
        if subtitles != .off {
            // Prefer full subtitles over "forced" (signs only) in the chosen language.
            let inLanguage = subs.filter { matches($0, subtitles.codes) }
            subIndex = (inLanguage.first { !isForced($0) } ?? inLanguage.first)?.index
        } else if let forced = subs.first(where: { isForced($0) && matches($0, audio.codes) }) {
            // Subtitles off still shows forced ones in the audio language (foreign dialogue).
            subIndex = forced.index
        }
        return TrackChoice(audioIndex: audioIndex, subtitleIndex: subIndex)
    }

    /// True when the choice differs from what the file plays by itself.
    public static func needsTrackControl(_ choice: TrackChoice, source: MediaSource) -> Bool {
        if choice.subtitleIndex != nil { return true }
        if let a = choice.audioIndex, a != source.defaultAudioStream?.index { return true }
        return false
    }

    /// VLC counts tracks inside the file, from 0, by type. Jellyfin numbers
    /// every stream of the file. Converts one to the other.
    public static func vlcPosition(of index: Int?, in streams: [MediaStream]) -> Int? {
        guard let index else { return nil }
        let internalOnes = streams.filter { $0.isExternal != true }
        return internalOnes.firstIndex { $0.index == index }
    }

    public static func label(_ s: MediaStream) -> String {
        if let t = s.displayTitle, !t.isEmpty { return t }
        let lang = s.language.map { Locale(identifier: "it").localizedString(forLanguageCode: $0) ?? $0 } ?? "Sconosciuta"
        return [lang, s.codec?.uppercased()].compactMap { $0 }.joined(separator: " · ")
    }

    static func matches(_ s: MediaStream, _ codes: [String]) -> Bool {
        guard let lang = s.language?.lowercased(), !codes.isEmpty else { return false }
        return codes.contains(lang)
    }

    static func isForced(_ s: MediaStream) -> Bool {
        let text = ((s.title ?? "") + " " + (s.displayTitle ?? "")).lowercased()
        return s.isForced == true || text.contains("forced") || text.contains("forzat")
    }
}
