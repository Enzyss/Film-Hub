import Foundation
import Observation
import JellyCore

/// S03: what to watch next. Shows the last copy instantly, then refreshes.
@MainActor
@Observable
final class HomeModel {
    struct Content: Codable, Equatable {
        var resume: [BaseItem] = []
        var nextUp: [BaseItem] = []
    }

    private(set) var content = Content()
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var errorMessage: String?

    init() {
        if let cached = JSONFile.read(Content.self, from: AppPaths.homeCache) {
            content = cached
            hasLoadedOnce = true
        }
    }

    var isEmpty: Bool { content.resume.isEmpty && content.nextUp.isEmpty }

    func load(api: JellyfinAPI?, onUnauthorized: () -> Void) async {
        guard let api else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // Both rows at once: the slower one sets the wait, not the sum.
            async let resume = api.resumeItems()
            async let nextUp = api.nextUp()
            let fresh = Content(resume: try await resume, nextUp: try await nextUp)
            content = fresh
            errorMessage = nil
            hasLoadedOnce = true
            JSONFile.write(fresh, to: AppPaths.homeCache)
        } catch is CancellationError {
            return
        } catch JellyfinError.unauthorized {
            onUnauthorized()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
