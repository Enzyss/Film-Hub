import Foundation

/// Where progress goes. JellyfinAPI in the app, a fake in tests.
public protocol ProgressTransport: Sendable {
    func reportStart(_ r: PlaybackReport) async throws
    func reportProgress(_ r: PlaybackReport) async throws
    func reportStopped(_ r: PlaybackReport) async throws
}

extension JellyfinAPI: ProgressTransport {}

/// A position not yet confirmed by the server.
public struct PendingProgress: Codable, Equatable, Sendable {
    public var itemId: String
    public var mediaSourceId: String?
    public var positionTicks: Int64
    public var runTimeTicks: Int64?
    public var recordedAt: Date

    /// Past 90% counts as watched, like the server's default.
    public var finished: Bool {
        guard let run = runTimeTicks, run > 0 else { return false }
        return Double(positionTicks) >= 0.9 * Double(run)
    }
}

public enum ReportKind: Sendable {
    case start, progress, stopped
}

/// Keeps watch progress safe. Every position is written to disk first, then sent.
/// A position leaves the disk only once the server has accepted it, so closing
/// the app or losing the network never loses it: `flush()` sends what is left.
///
/// The flush replays a position as a "playback stopped" report. Tested against
/// the user's Jellyfin 12 server: that updates Continue Watching even without a
/// live session, while writing user data directly is refused (403) for
/// non-admin users there.
public actor ProgressSync {
    private let fileURL: URL
    private var transport: (any ProgressTransport)?
    private var pending: [String: PendingProgress] = [:]
    private var flushing = false
    /// The item playing right now: its live session reports cover it, and a
    /// replayed "stopped" would end that session on the server.
    private var activeItemId: String?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([PendingProgress].self, from: data) {
            for p in list { pending[p.itemId] = p }
        }
    }

    public func setTransport(_ transport: (any ProgressTransport)?) {
        self.transport = transport
    }

    public var pendingItems: [PendingProgress] {
        pending.values.sorted { $0.recordedAt < $1.recordedAt }
    }

    /// Writes the position to disk. Never replaces a newer position with an older one.
    public func record(itemId: String, mediaSourceId: String? = nil, positionTicks: Int64,
                       runTimeTicks: Int64?, at date: Date = Date()) {
        if let existing = pending[itemId], existing.recordedAt > date { return }
        pending[itemId] = PendingProgress(itemId: itemId, mediaSourceId: mediaSourceId,
                                          positionTicks: positionTicks, runTimeTicks: runTimeTicks,
                                          recordedAt: date)
        save()
    }

    /// Records, then sends a live session report. Returns true if the server got it.
    @discardableResult
    public func report(_ kind: ReportKind, _ r: PlaybackReport, runTimeTicks: Int64?, at date: Date = Date()) async -> Bool {
        activeItemId = kind == .stopped ? nil : r.itemId
        // Nothing to save at the very start of an item that had no position.
        if !(kind == .start && r.positionTicks == 0) {
            record(itemId: r.itemId, mediaSourceId: r.mediaSourceId, positionTicks: r.positionTicks,
                   runTimeTicks: runTimeTicks, at: date)
        }
        guard let transport else { return false }
        do {
            switch kind {
            case .start: try await transport.reportStart(r)
            case .progress: try await transport.reportProgress(r)
            case .stopped: try await transport.reportStopped(r)
            }
            confirm(itemId: r.itemId, recordedAt: date)
            return true
        } catch {
            return false
        }
    }

    /// Sends everything left on disk. Safe to call often: it does nothing when
    /// there is nothing to send.
    public func flush() async {
        guard let transport, !flushing, !pending.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        for p in pendingItems where p.itemId != activeItemId {
            let replay = PlaybackReport(
                itemId: p.itemId,
                mediaSourceId: p.mediaSourceId,
                playSessionId: "filmhub-replay-\(UUID().uuidString)",
                positionTicks: p.positionTicks,
                isPaused: true,
                playMethod: "DirectPlay"
            )
            do {
                // Past 90% the server marks the item watched by itself.
                try await transport.reportStopped(replay)
                confirm(itemId: p.itemId, recordedAt: p.recordedAt)
            } catch {
                return  // Offline or server down: try again on the next flush.
            }
        }
    }

    private func confirm(itemId: String, recordedAt: Date) {
        // A newer position may have arrived while this one was in flight.
        guard let current = pending[itemId], current.recordedAt <= recordedAt else { return }
        pending[itemId] = nil
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(pendingItems)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Disk full or similar: the position stays in memory for this run.
        }
    }
}
