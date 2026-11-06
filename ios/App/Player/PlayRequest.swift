import Foundation
import JellyCore

/// One "play" tap: what to play and with which tracks.
struct PlayRequest: Identifiable, Equatable {
    let id = UUID()
    let item: BaseItem
    /// The version picked on the title page (HD, 4K...), if any.
    let source: MediaSource?
    /// Audio and subtitles picked on the title page, if any.
    let choice: TrackChoice?
    /// PlaybackInfo fetched while the title page was open: saves ~0.5 s on Play.
    var prefetched: Prefetched?

    struct Prefetched: Equatable {
        let info: PlaybackInfoResponse
        let choice: TrackChoice?
        let mediaSourceId: String?
        let at: Date

        /// Usable if recent and asked for the same tracks and version.
        func matches(choice: TrackChoice?, mediaSourceId: String?) -> Bool {
            Date().timeIntervalSince(at) < 60 && self.choice == choice && self.mediaSourceId == mediaSourceId
        }
    }
}
