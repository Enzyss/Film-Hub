import Foundation

/// What the Apple player (AVPlayer) can play without help, sent to the server in
/// PlaybackInfo so it can say whether a file plays directly. Anything outside it
/// goes to the VLC player instead; server transcoding is only the last resort.
public struct DeviceProfile: Encodable, Sendable {
    public struct DirectPlayProfile: Encodable, Sendable {
        public var container: String
        public var type: String
        public var videoCodec: String?
        public var audioCodec: String?
    }

    public struct TranscodingProfile: Encodable, Sendable {
        public var container: String
        public var type: String
        public var videoCodec: String
        public var audioCodec: String
        public var `protocol`: String
        public var context: String
        public var maxAudioChannels: String
        public var minSegments: Int
        public var breakOnNonKeyFrames: Bool
    }

    public struct SubtitleProfile: Encodable, Sendable {
        public var format: String
        public var method: String
    }

    public var name: String
    public var maxStreamingBitrate: Int
    public var maxStaticBitrate: Int
    public var directPlayProfiles: [DirectPlayProfile]
    public var transcodingProfiles: [TranscodingProfile]
    public var subtitleProfiles: [SubtitleProfile]
    public var codecProfiles: [String]
    public var containerProfiles: [String]

    public static let appleContainers: Set<String> = ["mp4", "m4v", "mov"]
    public static let appleVideoCodecs: Set<String> = ["h264", "hevc"]
    public static let appleAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]

    public static func apple(maxBitrate: Int = 120_000_000) -> DeviceProfile {
        DeviceProfile(
            name: "Film Hub (AVPlayer)",
            maxStreamingBitrate: maxBitrate,
            maxStaticBitrate: maxBitrate,
            directPlayProfiles: [
                DirectPlayProfile(
                    container: appleContainers.sorted().joined(separator: ","),
                    type: "Video",
                    videoCodec: appleVideoCodecs.sorted().joined(separator: ","),
                    audioCodec: appleAudioCodecs.sorted().joined(separator: ",")
                ),
            ],
            transcodingProfiles: [
                TranscodingProfile(
                    container: "mp4", type: "Video", videoCodec: "hevc,h264",
                    audioCodec: "aac,ac3,eac3", protocol: "hls", context: "Streaming",
                    maxAudioChannels: "6", minSegments: 1, breakOnNonKeyFrames: true
                ),
            ],
            subtitleProfiles: [
                SubtitleProfile(format: "vtt", method: "Hls"),
                SubtitleProfile(format: "srt", method: "External"),
                SubtitleProfile(format: "subrip", method: "External"),
                SubtitleProfile(format: "ass", method: "Encode"),
                SubtitleProfile(format: "ssa", method: "Encode"),
                SubtitleProfile(format: "pgssub", method: "Encode"),
                SubtitleProfile(format: "dvdsub", method: "Encode"),
            ],
            codecProfiles: [],
            containerProfiles: []
        )
    }
}

/// Body of POST /Items/{id}/PlaybackInfo.
public struct PlaybackInfoRequest: Encodable, Sendable {
    public var userId: String
    public var deviceProfile: DeviceProfile
    public var startTimeTicks: Int64?
    public var mediaSourceId: String?
    public var maxStreamingBitrate: Int
    public var enableDirectPlay = true
    public var enableDirectStream = true
    public var enableTranscoding = true
    public var allowVideoStreamCopy = true
    public var allowAudioStreamCopy = true
    public var autoOpenLiveStream = false
}
