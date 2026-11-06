import Foundation

/// A server-side query for one row or grid. Everything is filtered and sorted
/// by Jellyfin; the app never downloads the whole library.
public struct CatalogQuery: Codable, Hashable, Sendable {
    public var itemTypes: [String]
    public var genres: [String] = []
    public var studios: [String] = []
    public var sortBy: String = "DateCreated,SortName"
    public var descending: Bool = true
    public var unplayedOnly: Bool = false
    public var minCommunityRating: Double?
    public var searchTerm: String?

    public init(itemTypes: [String], genres: [String] = [], studios: [String] = [],
                sortBy: String = "DateCreated,SortName", descending: Bool = true,
                unplayedOnly: Bool = false, minCommunityRating: Double? = nil, searchTerm: String? = nil) {
        self.itemTypes = itemTypes
        self.genres = genres
        self.studios = studios
        self.sortBy = sortBy
        self.descending = descending
        self.unplayedOnly = unplayedOnly
        self.minCommunityRating = minCommunityRating
        self.searchTerm = searchTerm
    }

    /// Fields for cards: enough for poster, rating, progress and de-duplication.
    /// Never MediaSources: on the user's server that makes a 25-item page take 4.5 s.
    public static let cardFields = "ProviderIds,PrimaryImageAspectRatio,ChildCount,Genres"

    public func queryItems(userId: String, startIndex: Int, limit: Int) -> [URLQueryItem] {
        var q: [URLQueryItem] = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: itemTypes.joined(separator: ",")),
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "sortOrder", value: descending ? "Descending" : "Ascending"),
            URLQueryItem(name: "startIndex", value: String(startIndex)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: Self.cardFields),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
            URLQueryItem(name: "enableImageTypes", value: "Primary,Backdrop,Thumb"),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
        ]
        if !genres.isEmpty { q.append(URLQueryItem(name: "genres", value: genres.joined(separator: "|"))) }
        if !studios.isEmpty { q.append(URLQueryItem(name: "studios", value: studios.joined(separator: "|"))) }
        if unplayedOnly { q.append(URLQueryItem(name: "isPlayed", value: "false")) }
        if let r = minCommunityRating { q.append(URLQueryItem(name: "minCommunityRating", value: String(r))) }
        if let s = searchTerm, !s.isEmpty { q.append(URLQueryItem(name: "searchTerm", value: s)) }
        return q
    }
}

public struct CatalogRow: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var query: CatalogQuery
    /// Big cards for the first rows, posters for the rest.
    public var style: Style = .poster

    public enum Style: String, Codable, Sendable { case poster, wide }

    public init(id: String, title: String, query: CatalogQuery, style: Style = .poster) {
        self.id = id
        self.title = title
        self.query = query
        self.style = style
    }
}

public enum CatalogKind: String, CaseIterable, Codable, Sendable {
    case movies, series, documentaries

    public var title: String {
        switch self {
        case .movies: return "Film"
        case .series: return "Serie TV"
        case .documentaries: return "Documentari"
        }
    }

    var itemTypes: [String] {
        switch self {
        case .movies: return ["Movie"]
        case .series: return ["Series"]
        case .documentaries: return ["Movie", "Series"]
        }
    }
}

/// The user's server mixes Italian and English genre names ("Commedia" and
/// "Comedy"), so each section asks for all the spellings at once.
public struct GenreGroup: Sendable {
    public var title: String
    public var names: [String]

    public static let all: [GenreGroup] = [
        GenreGroup(title: "Azione", names: ["Azione", "Action", "Action & Adventure"]),
        GenreGroup(title: "Commedia", names: ["Commedia", "Comedy"]),
        GenreGroup(title: "Drammatici", names: ["Dramma", "Drammatici", "Drama"]),
        GenreGroup(title: "Thriller", names: ["Thriller", "Suspense"]),
        GenreGroup(title: "Crime", names: ["Crime"]),
        GenreGroup(title: "Fantascienza", names: ["Fantascienza", "Science Fiction", "Sci-Fi & Fantasy"]),
        GenreGroup(title: "Fantasy", names: ["Fantasy"]),
        GenreGroup(title: "Horror", names: ["Horror"]),
        GenreGroup(title: "Avventura", names: ["Avventura", "Adventure"]),
        GenreGroup(title: "Animazione", names: ["Animazione", "Animation"]),
        GenreGroup(title: "Famiglia", names: ["Famiglia", "Family", "Bambini", "Kids", "Children"]),
        GenreGroup(title: "Romantici", names: ["Romantici", "Romance"]),
        GenreGroup(title: "Mistero", names: ["Mistero", "Mystery"]),
        GenreGroup(title: "Guerra", names: ["Guerra", "War", "War & Politics"]),
        GenreGroup(title: "Storia", names: ["Storia", "History"]),
        GenreGroup(title: "Western", names: ["Western"]),
        GenreGroup(title: "Musica", names: ["Musica", "Music", "Musical"]),
        GenreGroup(title: "Reality", names: ["Reality"]),
    ]

    public static let documentary = ["Documentario", "Documentari", "Documentary"]
}

/// Platform sections, from the studios and networks in the server's metadata
/// (checked on the user's server: "Netflix", "Disney+", "Prime Video", ...).
public struct Platform: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var studios: [String]

    public static let all: [Platform] = [
        Platform(id: "netflix", title: "Netflix",
                 studios: ["Netflix", "Netflix International Pictures", "Netflix Animation Studios"]),
        Platform(id: "disney", title: "Disney+",
                 studios: ["Disney+", "Disney", "Walt Disney Pictures", "Walt Disney Animation Studios", "Pixar",
                           "Marvel Studios", "Lucasfilm Ltd.", "Lucasfilm Animation", "Disney Channel",
                           "Disney Television Animation", "Disney Jr.", "Disney Junior"]),
        Platform(id: "prime", title: "Prime Video",
                 studios: ["Prime Video", "Amazon Studios", "Amazon MGM Studios", "Amazon Freevee"]),
        Platform(id: "apple", title: "Apple TV+",
                 studios: ["Apple TV+", "Apple Studios", "Apple Original Films"]),
        Platform(id: "hbo", title: "HBO",
                 studios: ["HBO", "HBO Max", "Max", "HBO Films", "HBO Documentary Films"]),
        Platform(id: "paramount", title: "Paramount+",
                 studios: ["Paramount+", "Paramount+ with Showtime", "Showtime"]),
        Platform(id: "sky", title: "Sky",
                 studios: ["Sky", "Sky Atlantic", "Sky Atlantic (IT)", "Sky Original Productions", "Sky Cinema",
                           "Sky Serie", "Sky Documentaries", "Sky Nature"]),
        Platform(id: "rai", title: "Rai",
                 studios: ["RAI", "Rai Fiction", "RAI Cinema", "Rai 1", "Rai 2", "Rai 3", "Rai Documentari"]),
    ]
}

public enum Catalog {
    /// Rows for a tab, top to bottom.
    public static func rows(for kind: CatalogKind) -> [CatalogRow] {
        let types = kind.itemTypes
        var rows: [CatalogRow] = []

        if kind == .documentaries {
            let docs = GenreGroup.documentary
            rows.append(CatalogRow(id: "doc-recent", title: "Aggiunti di recente",
                                   query: CatalogQuery(itemTypes: ["Movie"], genres: docs), style: .wide))
            rows.append(CatalogRow(id: "doc-series", title: "Serie documentarie",
                                   query: CatalogQuery(itemTypes: ["Series"], genres: docs)))
            rows.append(CatalogRow(id: "doc-acclaimed", title: "Acclamati dalla critica",
                                   query: CatalogQuery(itemTypes: types, genres: docs,
                                                       sortBy: "CriticRating,CommunityRating")))
            rows.append(CatalogRow(id: "doc-discover", title: "Da scoprire",
                                   query: CatalogQuery(itemTypes: types, genres: docs, sortBy: "Random",
                                                       unplayedOnly: true, minCommunityRating: 7)))
            rows.append(CatalogRow(id: "doc-netflix", title: "Documentari Netflix",
                                   query: CatalogQuery(itemTypes: types, genres: docs,
                                                       studios: Platform.all[0].studios)))
            rows.append(CatalogRow(id: "doc-nature", title: "Natura e pianeta",
                                   query: CatalogQuery(itemTypes: types,
                                                       studios: ["National Geographic", "National Geographic Documentary Films",
                                                                 "National Geographic Wild", "Sky Nature", "BBC Earth",
                                                                 "BBC Natural History Unit"])))
            rows.append(CatalogRow(id: "doc-history", title: "Storia",
                                   query: CatalogQuery(itemTypes: types, genres: ["Storia", "History"],
                                                       sortBy: "CommunityRating,SortName")))
            return rows
        }

        rows.append(CatalogRow(id: "\(kind.rawValue)-recent", title: "Aggiunti di recente",
                               query: CatalogQuery(itemTypes: types), style: .wide))
        rows.append(CatalogRow(id: "\(kind.rawValue)-acclaimed", title: "Acclamati dalla critica",
                               query: CatalogQuery(itemTypes: types, sortBy: "CriticRating,CommunityRating",
                                                   minCommunityRating: 7)))
        rows.append(CatalogRow(id: "\(kind.rawValue)-discover", title: "Da non perdere",
                               query: CatalogQuery(itemTypes: types, sortBy: "Random", unplayedOnly: true,
                                                   minCommunityRating: 7.2)))
        for p in Platform.all {
            rows.append(CatalogRow(id: "\(kind.rawValue)-p-\(p.id)", title: p.title,
                                   query: CatalogQuery(itemTypes: types, studios: p.studios)))
        }
        for g in GenreGroup.all {
            if kind == .movies, g.title == "Reality" { continue }
            rows.append(CatalogRow(id: "\(kind.rawValue)-g-\(g.title)", title: g.title,
                                   query: CatalogQuery(itemTypes: types, genres: g.names,
                                                       sortBy: "CommunityRating,SortName", minCommunityRating: 6)))
        }
        return rows
    }

    /// Sort choices for the "see all" grid.
    public static let sorts: [(label: String, sortBy: String, descending: Bool)] = [
        ("Aggiunti di recente", "DateCreated,SortName", true),
        ("Più votati", "CommunityRating,SortName", true),
        ("Critica", "CriticRating,CommunityRating", true),
        ("Anno", "ProductionYear,SortName", true),
        ("Titolo", "SortName", false),
        ("Casuale", "Random", true),
    ]
}
