import SwiftUI
import JellyCore

extension BaseItem {
    /// Vertical poster. Episodes use their series' poster.
    func posterURL(api: JellyfinAPI?, width: Int) -> URL? {
        guard let api else { return nil }
        if isEpisode, let sid = seriesId, let tag = seriesPrimaryImageTag {
            return api.imageURL(itemId: sid, type: "Primary", tag: tag, width: width)
        }
        guard let tag = imageTag("Primary") else { return nil }
        return api.imageURL(itemId: id, type: "Primary", tag: tag, width: width)
    }

    /// Wide background art for heroes and the title page.
    func backdropURL(api: JellyfinAPI?, width: Int) -> URL? {
        guard let api else { return nil }
        if let tag = backdropImageTags?.first {
            return api.imageURL(itemId: id, type: "Backdrop", tag: tag, width: width)
        }
        if let pid = parentBackdropItemId, let tag = parentBackdropImageTags?.first {
            return api.imageURL(itemId: pid, type: "Backdrop", tag: tag, width: width)
        }
        return landscapeImageURL(api: api, width: width)
    }

    var hasBackdrop: Bool {
        !(backdropImageTags ?? []).isEmpty || !(parentBackdropImageTags ?? []).isEmpty
    }
}

/// Audience and critics scores, small.
struct RatingBadges: View {
    let item: BaseItem
    var compact = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let r = item.ratingLabel {
                Text(r).foregroundStyle(Theme.Colors.accent)
            }
            if let c = item.criticLabel {
                Label(c, systemImage: "rosette")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .font(compact ? .caption2.weight(.semibold) : .footnote.weight(.semibold))
    }
}

/// 2:3 poster with score, progress and a watched tick.
struct PosterCard: View {
    let item: BaseItem
    let api: JellyfinAPI?
    var width: CGFloat = Theme.Size.posterWidth

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: item.posterURL(api: api, width: Int(width * 2)))
                        .frame(width: width, height: width * 1.5)
                        .clipped()
                    if let p = item.progress, !item.isPlayed {
                        ProgressBar(value: p)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))

                if item.isPlayed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.white, Theme.Colors.accent)
                        .padding(Theme.Space.xs)
                }
            }
            Text(item.name ?? "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
            HStack(spacing: Theme.Space.xs) {
                if let y = item.productionYear {
                    Text(String(y)).foregroundStyle(Theme.Colors.textSecondary)
                }
                if let r = item.ratingLabel {
                    Text(r).foregroundStyle(Theme.Colors.accent)
                }
            }
            .font(.caption2)
            .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct RowHeader: View {
    let title: String
    var showsMore = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.Colors.textPrimary)
            Spacer()
            if showsMore {
                HStack(spacing: 2) {
                    Text("Vedi tutto")
                    Image(systemName: "chevron.right")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Colors.accent)
            }
        }
        .padding(.horizontal, Theme.Space.l)
    }
}

/// Horizontal row of titles. Tapping opens the title page.
struct ItemRow: View {
    let title: String
    let items: [BaseItem]
    let api: JellyfinAPI?
    var style: CatalogRow.Style = .poster
    var seeAll: CatalogRow?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let seeAll {
                NavigationLink(value: seeAll) { RowHeader(title: title) }
                    .buttonStyle(.plain)
            } else {
                RowHeader(title: title, showsMore: false)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.m) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            switch style {
                            case .poster: PosterCard(item: item, api: api)
                            case .wide: LandscapeCard(item: item, api: api)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Space.l)
            }
        }
    }
}

struct SkeletonPosterRow: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            RowHeader(title: title, showsMore: false)
            HStack(spacing: Theme.Space.m) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(Theme.Colors.surface)
                        .frame(width: Theme.Size.posterWidth, height: Theme.Size.posterWidth * 1.5)
                }
            }
            .padding(.horizontal, Theme.Space.l)
        }
    }
}

/// Big rotating banner at the top of a tab.
struct HeroCarousel: View {
    let items: [BaseItem]
    let api: JellyfinAPI?
    @State private var index = 0

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                NavigationLink(value: item) {
                    HeroCard(item: item, api: api)
                }
                .buttonStyle(.plain)
                .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .frame(height: Theme.Size.heroHeight)
        .task(id: items.count) {
            guard items.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count }
            }
        }
    }
}

struct HeroCard: View {
    let item: BaseItem
    let api: JellyfinAPI?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: item.backdropURL(api: api, width: 1280))
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Size.heroHeight)
                .clipped()
            LinearGradient(colors: [.clear, Theme.Colors.background.opacity(0.6), Theme.Colors.background],
                           startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(item.name ?? "")
                    .font(.title.weight(.heavy))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(2)
                HStack(spacing: Theme.Space.m) {
                    Text(item.metaLine)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    RatingBadges(item: item, compact: true)
                }
                .font(.caption)
                if let o = item.overview, !o.isEmpty {
                    Text(o)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.xxl)
        }
    }
}
