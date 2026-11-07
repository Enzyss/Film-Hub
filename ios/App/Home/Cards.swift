import SwiftUI
import JellyCore

extension BaseItem {
    /// A wide image for landscape cards: thumb, backdrop, then the series' art, then the poster.
    func landscapeImageURL(api: JellyfinAPI?, width: Int) -> URL? {
        guard let api else { return nil }
        if let tag = imageTag("Thumb") {
            return api.imageURL(itemId: id, type: "Thumb", tag: tag, width: width)
        }
        if isEpisode, let tag = imageTag("Primary") {
            return api.imageURL(itemId: id, type: "Primary", tag: tag, width: width)
        }
        if let tag = backdropImageTags?.first {
            return api.imageURL(itemId: id, type: "Backdrop", tag: tag, width: width)
        }
        if let pid = parentThumbItemId, let tag = parentThumbImageTag {
            return api.imageURL(itemId: pid, type: "Thumb", tag: tag, width: width)
        }
        if let pid = parentBackdropItemId, let tag = parentBackdropImageTags?.first {
            return api.imageURL(itemId: pid, type: "Backdrop", tag: tag, width: width)
        }
        if let tag = imageTag("Primary") {
            return api.imageURL(itemId: id, type: "Primary", tag: tag, width: width)
        }
        return nil
    }
}

/// Image with a quiet placeholder. URLCache keeps the bytes on disk between launches.
struct RemoteImage: View {
    let url: URL?

    var body: some View {
        // The image fills the space it is given and is cropped to it. Laid out
        // as an overlay on an empty view, so a picture bigger than its frame
        // can never widen the page (it did on the title page: everything
        // shifted and was cut at both edges).
        Color.clear
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder(icon: "film")
                    default:
                        placeholder(icon: nil)
                    }
                }
            }
            .clipped()
    }

    private func placeholder(icon: String?) -> some View {
        ZStack {
            Theme.Colors.surface
            if let icon {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.Colors.progressTrack)
                Rectangle().fill(Theme.Colors.accent)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: Theme.Size.progressHeight)
    }
}

/// 16:9 card with title, subtitle and progress. Used by Continue Watching and Next Up.
struct LandscapeCard: View {
    let item: BaseItem
    let api: JellyfinAPI?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: item.landscapeImageURL(api: api, width: Int(Theme.Size.landscapeCardWidth * 2)))
                    .frame(width: Theme.Size.landscapeCardWidth, height: Theme.Size.landscapeCardWidth * 9 / 16)
                    .clipped()
                if let p = item.progress {
                    ProgressBar(value: p)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                if let sub = item.displaySubtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: Theme.Size.landscapeCardWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Riproduci")
    }
}

/// Grey card shown while a row loads.
struct SkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Colors.surface)
                .frame(width: Theme.Size.landscapeCardWidth, height: Theme.Size.landscapeCardWidth * 9 / 16)
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.Colors.surface)
                .frame(width: 140, height: 12)
        }
        .redacted(reason: .placeholder)
    }
}
