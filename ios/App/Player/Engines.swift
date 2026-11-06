import AVFoundation
import MobileVLCKit
import UIKit

enum EngineStatus: Equatable {
    case opening
    case playing
    case paused
    case buffering
    case ended
    case failed(String)
}

/// What the player screen needs from a video engine. Both engines are polled by
/// PlayerModel; neither calls back, so there is one source of truth for state.
@MainActor
protocol PlaybackEngine: AnyObject {
    var view: UIView { get }
    var currentSeconds: Double { get }
    var durationSeconds: Double { get }
    var status: EngineStatus { get }
    func load(url: URL, startSeconds: Double)
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
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
    var view: UIView { layerView }

    init() {
        layerView.backgroundColor = .black
        layerView.playerLayer.player = player
        layerView.playerLayer.videoGravity = .resizeAspect
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func load(url: URL, startSeconds: Double) {
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 30
        player.replaceCurrentItem(with: item)
        if startSeconds > 0 {
            player.seek(to: CMTime(seconds: startSeconds, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
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
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - VLC (MobileVLCKit)

@MainActor
final class VLCEngine: PlaybackEngine {
    private let player = VLCMediaPlayer()
    private let drawable = UIView()
    private var hasStarted = false
    var view: UIView { drawable }

    init() {
        drawable.backgroundColor = .black
        player.drawable = drawable
    }

    func load(url: URL, startSeconds: Double) {
        let media = VLCMedia(url: url)
        // A bigger network buffer: fewer stalls on slow or distant servers (P1).
        media.addOption(":network-caching=3000")
        if startSeconds > 0 {
            media.addOption(":start-time=\(String(format: "%.1f", startSeconds))")
        }
        player.media = media
        hasStarted = false
        player.play()
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
        if player.isPlaying { hasStarted = true }
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
}
