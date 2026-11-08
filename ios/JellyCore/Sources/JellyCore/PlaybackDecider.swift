import Foundation

public enum PlayerPreference: String, CaseIterable, Codable, Sendable {
    case automatic
    case alwaysVLC
    case preferApple

    public var label: String {
        switch self {
        case .automatic: return "Automatico"
        case .alwaysVLC: return "Sempre VLC (più veloce)"
        case .preferApple: return "Sempre Apple (PiP)"
        }
    }
}

/// One way to play an item. The player tries the routes in order and moves to
/// the next one if a route cannot open.
public enum PlaybackRoute: Equatable, Sendable {
    case appleDirect(URL)
    case vlcDirect(URL)
    case appleTranscode(URL)

    public var url: URL {
        switch self {
        case .appleDirect(let u), .vlcDirect(let u), .appleTranscode(let u): return u
        }
    }

    public var usesVLC: Bool {
        if case .vlcDirect = self { return true }
        return false
    }

    /// Value for PlayMethod in progress reports.
    public var playMethod: String {
        switch self {
        case .appleDirect, .vlcDirect: return "DirectPlay"
        case .appleTranscode: return "Transcode"
        }
    }

    public var label: String {
        switch self {
        case .appleDirect: return "Apple"
        case .vlcDirect: return "VLC"
        case .appleTranscode: return "Convertito dal server"
        }
    }
}

public enum PlaybackDecider {
    /// Can AVPlayer play this file as it is?
    public static func isAppleCompatible(_ source: MediaSource) -> Bool {
        let containers = (source.container ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard containers.contains(where: { DeviceProfile.appleContainers.contains($0) }) else { return false }

        guard let video = source.videoStream,
              let vcodec = video.codec?.lowercased(),
              DeviceProfile.appleVideoCodecs.contains(vcodec) else { return false }
        // AVPlayer refuses HEVC tagged "hev1"; it needs "hvc1".
        if vcodec == "hevc", video.codecTag?.lowercased() == "hev1" { return false }

        if let audio = source.defaultAudioStream {
            guard let acodec = audio.codec?.lowercased(),
                  DeviceProfile.appleAudioCodecs.contains(acodec) else { return false }
        }

        // The server checked the same profile; if it disagrees, trust it.
        return source.supportsDirectPlay != false
    }

    /// Files the server only needs to repackage for the Apple player: the video
    /// is copied as is, the audio too. Tested on the user's server: such MKVs
    /// start in ~5-6 s through the server (VLC: 3-5 s), and get Picture in
    /// Picture. Dolby Vision with TrueHD took 25 s, DTS 7.7 s: those stay on VLC.
    public static func isRepackagedQuickly(_ source: MediaSource) -> Bool {
        guard let video = source.videoStream,
              let vcodec = video.codec?.lowercased(),
              DeviceProfile.appleVideoCodecs.contains(vcodec) else { return false }
        if let range = video.videoRangeType, range.uppercased().contains("DOVI") { return false }
        guard let audio = source.defaultAudioStream else { return true }
        guard let acodec = audio.codec?.lowercased() else { return false }
        return DeviceProfile.appleAudioCodecs.contains(acodec)
    }

    /// The first Apple-friendly container, used as the stream URL extension.
    public static func appleExtension(for source: MediaSource) -> String {
        let containers = (source.container ?? "").lowercased().split(separator: ",").map(String.init)
        return containers.first { DeviceProfile.appleContainers.contains($0) } ?? "mp4"
    }

    public static func routes(
        appleCompatible: Bool,
        appleStaticURL: URL,
        staticURL: URL,
        transcodeURL: URL?,
        preference: PlayerPreference,
        needsTrackControl: Bool = false,
        repackagedQuickly: Bool = false,
        subtitlesOn: Bool = false
    ) -> [PlaybackRoute] {
        // A non-default audio track or any subtitle: VLC picks and loads them
        // reliably on direct play; the Apple player cannot load external files.
        let appleCompatible = appleCompatible && !needsTrackControl
        var routes: [PlaybackRoute] = []
        switch preference {
        case .automatic:
            if appleCompatible {
                routes.append(.appleDirect(appleStaticURL))
                routes.append(.vlcDirect(staticURL))
                if let t = transcodeURL { routes.append(.appleTranscode(t)) }
            } else if let t = transcodeURL, repackagedQuickly, !subtitlesOn {
                // Apple player through the server: Picture in Picture works,
                // also by itself when leaving the app. VLC if it fails.
                routes.append(.appleTranscode(t))
                routes.append(.vlcDirect(staticURL))
            } else {
                routes.append(.vlcDirect(staticURL))
                if let t = transcodeURL { routes.append(.appleTranscode(t)) }
            }
        case .alwaysVLC:
            routes.append(.vlcDirect(staticURL))
            if let t = transcodeURL { routes.append(.appleTranscode(t)) }
        case .preferApple:
            if appleCompatible { routes.append(.appleDirect(appleStaticURL)) }
            if let t = transcodeURL { routes.append(.appleTranscode(t)) }
            routes.append(.vlcDirect(staticURL))
        }
        return routes
    }
}
