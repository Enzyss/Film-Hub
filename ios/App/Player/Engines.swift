import AVFoundation
import AVKit
@preconcurrency import MobileVLCKit
import UIKit

enum EngineStatus: Equatable {
    case opening
    case playing
    case paused
    case buffering
    case ended
    case failed(String)
}

/// A track as the engine itself names it, for the in-player menu.
struct EngineTrack: Identifiable, Equatable {
    let id: Int
    let name: String
}

/// Tracks to start with, worked out from the user's choice.
struct StartTracks: Equatable {
    /// VLC: position among the file's audio tracks.
    var audioPosition: Int?
    /// VLC: position among the file's subtitle tracks.
    var subtitlePosition: Int?
    /// A subtitle file to load next to the video (external or text track).
    var externalSubtitle: URL?
    var subtitlesOff = false

    static let none = StartTracks()
}

enum PiPEvent: Equatable {
    case started
    /// The PiP window closed (by its X, or after a restore).
    case stopped
    /// The user tapped "back to the app" in the PiP window.
    case restore
    case failed(String)
}

/// AVKit calls back on the main thread; this hands each event to a closure.
final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    var onEvent: ((PiPEvent) -> Void)?

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        onEvent?(.started)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        onEvent?(.stopped)
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        onEvent?(.failed(error.localizedDescription))
    }

    func pictureInPictureController(
        _ c: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        onEvent?(.restore)
        completionHandler(true)
    }
}

/// What the player screen needs from a video engine. Both engines are polled by
/// PlayerModel; neither calls back, so there is one source of truth for state.
@MainActor
protocol PlaybackEngine: AnyObject {
    var view: UIView { get }
    var currentSeconds: Double { get }
    var durationSeconds: Double { get }
    var status: EngineStatus { get }
    func load(url: URL, startSeconds: Double, tracks: StartTracks)
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()

    var audioTracks: [EngineTrack] { get }
    var subtitleTracks: [EngineTrack] { get }
    var currentAudio: Int? { get }
    var currentSubtitle: Int? { get }
    func selectAudio(_ id: Int)
    /// nil turns subtitles off.
    func selectSubtitle(_ id: Int?)

    /// Picture in Picture: only the Apple player has it on iPhone.
    var supportsPiP: Bool { get }
    var isPiPPossible: Bool { get }
    /// Returns false if PiP cannot start yet (the video is not ready).
    func startPiP() -> Bool
    func stopPiP()
    var onPiP: ((PiPEvent) -> Void)? { get set }
}

// MARK: - Apple (AVPlayer)

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

@MainActor
final class AppleEngine: PlaybackEngine {
    private let player = AVPlayer()
    private let layerView = PlayerLayerView()
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var pip: AVPictureInPictureController?
    private let pipDelegate = PiPDelegate()
    var view: UIView { layerView }
    var onPiP: ((PiPEvent) -> Void)?

    init() {
        layerView.backgroundColor = .black
        layerView.playerLayer.player = player
        layerView.playerLayer.videoGravity = .resizeAspect
        player.automaticallyWaitsToMinimizeStalling = true
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let controller = AVPictureInPictureController(playerLayer: layerView.playerLayer)
            // Going to the home screen while playing turns into PiP by itself.
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
            controller?.delegate = pipDelegate
            pip = controller
        }
        pipDelegate.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.onPiP?(event) }
        }
    }

    static var isPiPSupportedOnDevice: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var supportsPiP: Bool { pip != nil }
    var isPiPPossible: Bool { pip?.isPictureInPicturePossible == true }

    func startPiP() -> Bool {
        guard let pip, pip.isPictureInPicturePossible else { return false }
        pip.startPictureInPicture()
        return true
    }

    func stopPiP() { pip?.stopPictureInPicture() }

    func load(url: URL, startSeconds: Double, tracks: StartTracks) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        player.replaceCurrentItem(with: item)
        if startSeconds > 0 {
            player.seek(to: CMTime(seconds: startSeconds, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        Task { [weak self] in
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            self?.audioGroup = audio
            self?.legibleGroup = legible
        }
    }

    var currentSeconds: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(t, 0) : 0
    }

    var durationSeconds: Double {
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return 0 }
        return d
    }

    var status: EngineStatus {
        guard let item = player.currentItem else { return .opening }
        if item.status == .failed {
            return .failed(item.error?.localizedDescription ?? "Il player Apple non riesce ad aprire il file.")
        }
        if item.status == .unknown { return .opening }
        let d = durationSeconds
        if d > 0, currentSeconds >= d - 0.5, player.timeControlStatus == .paused { return .ended }
        switch player.timeControlStatus {
        case .playing: return .playing
        case .paused: return .paused
        case .waitingToPlayAtSpecifiedRate: return .buffering
        @unknown default: return .buffering
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(seconds, 0), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        pip?.stopPictureInPicture()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // Tracks, from the file's media selection groups.

    private func tracks(_ group: AVMediaSelectionGroup?) -> [EngineTrack] {
        guard let group else { return [] }
        return group.options.enumerated().map { i, o in EngineTrack(id: i, name: o.displayName) }
    }

    private func selected(_ group: AVMediaSelectionGroup?) -> Int? {
        guard let group, let item = player.currentItem,
              let option = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return group.options.firstIndex(of: option)
    }

    var audioTracks: [EngineTrack] { tracks(audioGroup) }
    var subtitleTracks: [EngineTrack] { tracks(legibleGroup) }
    var currentAudio: Int? { selected(audioGroup) }
    var currentSubtitle: Int? { selected(legibleGroup) }

    func selectAudio(_ id: Int) {
        guard let group = audioGroup, group.options.indices.contains(id) else { return }
        player.currentItem?.select(group.options[id], in: group)
    }

    func selectSubtitle(_ id: Int?) {
        guard let group = legibleGroup else { return }
        if let id, group.options.indices.contains(id) {
            player.currentItem?.select(group.options[id], in: group)
        } else {
            player.currentItem?.select(nil, in: group)
        }
    }
}

// MARK: - VLC (MobileVLCKit)

@MainActor
final class VLCEngine: PlaybackEngine {
    private let player = VLCMediaPlayer()
    private let drawable = UIView()
    private var hasStarted = false
    private var pending: StartTracks = .none
    private var appliedPending = false
    var view: UIView { drawable }
    var onPiP: ((PiPEvent) -> Void)?
    var supportsPiP: Bool { false }
    var isPiPPossible: Bool { false }
    func startPiP() -> Bool { false }
    func stopPiP() {}

    init() {
        drawable.backgroundColor = .black
        player.drawable = drawable
    }

    func load(url: URL, startSeconds: Double, tracks: StartTracks) {
        let media = VLCMedia(url: url)
        // 1.5 s of buffer before the first frame: starts sooner than VLC's usual
        // 3 s; the server sends 66-90 Mbit/s, and the stall watchdog covers dips.
        media.addOption(":network-caching=1500")
        // Reopen the HTTP connection by itself if it drops mid-film (P1).
        media.addOption(":http-reconnect")
        if startSeconds > 0 {
            media.addOption(":start-time=\(String(format: "%.1f", startSeconds))")
        }
        if let a = tracks.audioPosition { media.addOption(":audio-track=\(a)") }
        if let s = tracks.subtitlePosition { media.addOption(":sub-track=\(s)") }
        pending = tracks
        appliedPending = false
        player.media = media
        hasStarted = false
        player.play()
    }

    /// Some choices only work once the video runs: loading a subtitle file,
    /// and turning off subtitles the file marks as default.
    private func applyPendingTracks() {
        guard !appliedPending else { return }
        appliedPending = true
        if let url = pending.externalSubtitle {
            _ = player.addPlaybackSlave(url, type: .subtitle, enforce: true)
        } else if pending.subtitlesOff {
            player.currentVideoSubTitleIndex = -1
        }
    }

    var currentSeconds: Double {
        let t: VLCTime? = player.time
        return Double(t?.intValue ?? 0) / 1000
    }

    var durationSeconds: Double {
        let media: VLCMedia? = player.media
        let length: VLCTime? = media?.length
        return max(Double(length?.intValue ?? 0) / 1000, 0)
    }

    var status: EngineStatus {
        let state = player.state
        if player.isPlaying {
            hasStarted = true
            applyPendingTracks()
        }
        switch state {
        case .error:
            return .failed("VLC non riesce ad aprire il file.")
        case .ended:
            return .ended
        case .stopped:
            return hasStarted ? .ended : .opening
        case .opening:
            return .opening
        case .paused:
            return .paused
        case .playing:
            return .playing
        case .buffering:
            // VLC reports "buffering" often while it is in fact playing.
            return player.isPlaying ? .playing : (hasStarted ? .buffering : .opening)
        default:
            return player.isPlaying ? .playing : .buffering
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        player.time = VLCTime(int: Int32(max(seconds, 0) * 1000))
    }

    func stop() {
        // Stopping VLC can block for a moment; keep it off the main thread
        // so the interface never freezes on close.
        let p = player
        DispatchQueue.global(qos: .userInitiated).async {
            p.stop()
        }
    }

    // Tracks, as VLC lists them. Index -1 is VLC's "disabled" entry.

    private func list(ids: [Any]?, names: [Any]?) -> [EngineTrack] {
        let i = (ids as? [NSNumber])?.map(\.intValue) ?? []
        let n = (names as? [String]) ?? []
        return zip(i, n).filter { $0.0 >= 0 }.map { EngineTrack(id: $0.0, name: $0.1) }
    }

    var audioTracks: [EngineTrack] { list(ids: player.audioTrackIndexes, names: player.audioTrackNames) }
    var subtitleTracks: [EngineTrack] { list(ids: player.videoSubTitlesIndexes, names: player.videoSubTitlesNames) }

    var currentAudio: Int? {
        let i = Int(player.currentAudioTrackIndex)
        return i >= 0 ? i : nil
    }

    var currentSubtitle: Int? {
        let i = Int(player.currentVideoSubTitleIndex)
        return i >= 0 ? i : nil
    }

    func selectAudio(_ id: Int) { player.currentAudioTrackIndex = Int32(id) }
    func selectSubtitle(_ id: Int?) { player.currentVideoSubTitleIndex = Int32(id ?? -1) }
}
