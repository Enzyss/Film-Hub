import Foundation

/// Where progress goes. JellyfinAPI in the app, a fake in tests.
public protocol ProgressTransport: Sendable {
    func reportStart(_ r: PlaybackReport) async throws
    func reportProgress(_ r: PlaybackReport) async throws
    func reportStopped(_ r: PlaybackReport) async throws
    func saveUserData(itemId: String, update: UserDataUpdate) async throws
}

extension JellyfinAPI: ProgressTransport {}

/// A position not yet confirmed by the server.
public struct PendingProgress: Codable, Equatable, Sendable {
    public var itemId: String
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
public actor ProgressSync {
    private let fileURL: URL
    private var transport: (any ProgressTransport)?
    private var pending: [String: PendingProgress] = [:]
    private var flushing = false

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
    public func record(itemId: String, positionTicks: Int64, runTimeTicks: Int64?, at date: Date = Date()) {
        if let existing = pending[itemId], existing.recordedAt > date { return }
        pending[itemId] = PendingProgress(itemId: itemId, positionTicks: positionTicks,
                                          runTimeTicks: runTimeTicks, recordedAt: date)
        save()
    }

    /// Records, then sends a live session report. Returns true if the server got it.
    @discardableResult
    public func report(_ kind: ReportKind, _ r: PlaybackReport, runTimeTicks: Int64?, at date: Date = Date()) async -> Bool {
        // Nothing to save at the very start of an item that had no position.
        if !(kind == .start && r.positionTicks == 0) {
            record(itemId: r.itemId, positionTicks: r.positionTicks, runTimeTicks: runTimeTicks, at: date)
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

    /// Sends everything left on disk, directly to the item's user data.
    /// Safe to call often: it does nothing when there is nothing to send.
    public func flush() async {
        guard let transport, !flushing, !pending.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        for p in pendingItems {
            let update = p.finished
                ? UserDataUpdate(playbackPositionTicks: 0, played: true, lastPlayedDate: Self.iso(p.recordedAt))
                : UserDataUpdate(playbackPositionTicks: p.positionTicks, lastPlayedDate: Self.iso(p.recordedAt))
            do {
                try await transport.saveUserData(itemId: p.itemId, update: update)
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

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
