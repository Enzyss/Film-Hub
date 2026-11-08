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
    /// Only titles with a TMDB entry: filters out home videos and odd uploads.
    public var knownTitlesOnly: Bool = false
    /// Hide titles dated in the future (announced, not yet out).
    public var releasedOnly: Bool = false
    /// Libraries to read from. Empty = the whole server. Jellyfin takes one
    /// library per request, so several mean several requests, merged.
    public var parentIds: [String] = []
    /// Extra fields beyond the card ones (search asks for ParentId and Studios).
    public var extraFields: [String] = []

    public init(itemTypes: [String], genres: [String] = [], studios: [String] = [],
                sortBy: String = "DateCreated,SortName", descending: Bool = true,
                unplayedOnly: Bool = false, minCommunityRating: Double? = nil, searchTerm: String? = nil,
                knownTitlesOnly: Bool = false, releasedOnly: Bool = false,
                parentIds: [String] = [], extraFields: [String] = []) {
        self.parentIds = parentIds
        self.extraFields = extraFields
        self.knownTitlesOnly = knownTitlesOnly
        self.releasedOnly = releasedOnly
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

    public func queryItems(userId: String, startIndex: Int, limit: Int, parentId: String? = nil,
                           now: Date = Date()) -> [URLQueryItem] {
        let fields = ([Self.cardFields] + extraFields).joined(separator: ",")
        var q: [URLQueryItem] = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: itemTypes.joined(separator: ",")),
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "sortOrder", value: descending ? "Descending" : "Ascending"),
            URLQueryItem(name: "startIndex", value: String(startIndex)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: fields),
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
        if knownTitlesOnly { q.append(URLQueryItem(name: "hasTmdbId", value: "true")) }
        if let parentId { q.append(URLQueryItem(name: "parentId", value: parentId)) }
        if releasedOnly {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate]
            q.append(URLQueryItem(name: "maxPremiereDate", value: f.string(from: now)))
        }
        return q
    }
}

/// Where the next page of a query starts, per library.
public struct CatalogCursor: Hashable, Sendable {
    public var offsets: [String: Int] = [:]
    public var exhausted: Set<String> = []

    public init() {}

    public static let start = CatalogCursor()

    /// Library keys of a query: "" stands for the whole server.
    public static func keys(for query: CatalogQuery) -> [String] {
        query.parentIds.isEmpty ? [""] : query.parentIds
    }

    public func isFinished(for query: CatalogQuery) -> Bool {
        Self.keys(for: query).allSatisfy { exhausted.contains($0) }
    }

    /// One from each library in turn, so rows mix them instead of listing
    /// one library first.
    public static func interleave(_ lists: [[BaseItem]]) -> [BaseItem] {
        var out: [BaseItem] = []
        let longest = lists.map(\.count).max() ?? 0
        for i in 0..<longest {
            for list in lists where i < list.count { out.append(list[i]) }
        }
        return out
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
    case movies, series, anime, documentaries

    public var title: String {
        switch self {
        case .movies: return "Film"
        case .series: return "Serie TV"
        case .anime: return "Anime"
        case .documentaries: return "Documentari"
        }
    }

    var itemTypes: [String] {
        switch self {
        case .movies: return ["Movie"]
        case .series, .anime: return ["Series"]
        case .documentaries: return ["Movie", "Series"]
        }
    }
}

/// The user's anime libraries, found by name on the server ("Anime",
/// "Anime SUB ITA", "Anime ENG"), adult ones left out.
public struct AnimeLibraries: Codable, Hashable, Sendable {
    public var all: [String] = []
    public var dubbed: String?
    public var subbed: String?
    /// Folder ids the series in those libraries report as ParentId (they
    /// differ from the library ids): used to tell anime apart in search.
    public var folderIds: [String] = []

    public init(all: [String] = [], dubbed: String? = nil, subbed: String? = nil, folderIds: [String] = []) {
        self.all = all
        self.dubbed = dubbed
        self.subbed = subbed
        self.folderIds = folderIds
    }

    public static let none = AnimeLibraries()

    public static func isAnimeLibrary(name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("anime") && !n.contains("hentai")
    }

    /// Picks the libraries from the user's views (name and id).
    public static func from(views: [(name: String, id: String)]) -> AnimeLibraries {
        let anime = views.filter { isAnimeLibrary(name: $0.name) }
        let subbed = anime.first { $0.name.lowercased().contains("sub") }?.id
        let dubbed = anime.first {
            let n = $0.name.lowercased()
            return !n.contains("sub") && !n.contains("eng")
        }?.id
        return AnimeLibraries(all: anime.map(\.id), dubbed: dubbed, subbed: subbed)
    }
}

/// Japanese animation studios on the user's server: how anime films are found
/// (they sit in "Film Animati" next to Pixar and DreamWorks).
public enum AnimeStudios {
    public static let all = [
        "Toei Animation", "Studio Ghibli", "MAPPA", "Kyoto Animation", "Madhouse", "Production I.G",
        "BONES", "SUNRISE", "TMS Entertainment", "Pierrot", "WIT STUDIO", "ufotable", "CoMix Wave Films",
        "A-1 Pictures", "CloverWorks", "TRIGGER", "Aniplex", "Toho Animation", "SHAFT", "David Production",
        "Science SARU",
    ]
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

    public static let crunchyroll = Platform(id: "crunchyroll", title: "Crunchyroll",
                                             studios: ["Crunchyroll", "Crunchyroll Channel"])

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
    public static func rows(for kind: CatalogKind, anime: AnimeLibraries = .none) -> [CatalogRow] {
        let types = kind.itemTypes
        var rows: [CatalogRow] = []

        if kind == .anime { return animeRows(anime) }

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
            // Newest releases rated 6.5+: tested on the user's server, sorting
            // by score alone surfaces obscure 10/10 titles with a few votes.
            rows.append(CatalogRow(id: "\(kind.rawValue)-g-\(g.title)", title: g.title,
                                   query: CatalogQuery(itemTypes: types, genres: g.names,
                                                       sortBy: "PremiereDate,SortName", minCommunityRating: 6.5,
                                                       knownTitlesOnly: true, releasedOnly: true)))
        }
        return rows
    }

    /// Genres that make sense for anime, from the ones the anime libraries use.
    static let animeGenreTitles: Set<String> = [
        "Azione", "Commedia", "Drammatici", "Fantascienza", "Fantasy", "Avventura", "Romantici",
        "Mistero", "Horror", "Thriller", "Crime",
    ]

    static func animeRows(_ libs: AnimeLibraries) -> [CatalogRow] {
        // Without anime libraries, fall back to the "Anime" genre tag.
        let parents = libs.all
        let base = parents.isEmpty
            ? CatalogQuery(itemTypes: ["Series"], genres: ["Anime"])
            : CatalogQuery(itemTypes: ["Series"], parentIds: parents)
        func q(_ edit: (inout CatalogQuery) -> Void) -> CatalogQuery {
            var c = base
            edit(&c)
            return c
        }
        var rows: [CatalogRow] = []
        rows.append(CatalogRow(id: "anime-recent", title: "Aggiunti di recente", query: base, style: .wide))
        rows.append(CatalogRow(id: "anime-new", title: "Ultime uscite", query: q {
            $0.sortBy = "PremiereDate,SortName"; $0.releasedOnly = true; $0.knownTitlesOnly = true
        }))
        if let d = libs.dubbed {
            rows.append(CatalogRow(id: "anime-dub", title: "Doppiati in italiano",
                                   query: CatalogQuery(itemTypes: ["Series"], parentIds: [d])))
        }
        if let s = libs.subbed {
            rows.append(CatalogRow(id: "anime-sub", title: "Sottotitolati in italiano",
                                   query: CatalogQuery(itemTypes: ["Series"], parentIds: [s])))
        }
        rows.append(CatalogRow(id: "anime-movies", title: "Film anime",
                               query: CatalogQuery(itemTypes: ["Movie"], studios: AnimeStudios.all,
                                                   sortBy: "PremiereDate,SortName", releasedOnly: true)))
        rows.append(CatalogRow(id: "anime-discover", title: "Da non perdere", query: q {
            $0.sortBy = "Random"; $0.unplayedOnly = true; $0.minCommunityRating = 7.5; $0.knownTitlesOnly = true
        }))
        for p in [Platform.crunchyroll] + Platform.all.filter({ ["netflix", "disney", "prime"].contains($0.id) }) {
            rows.append(CatalogRow(id: "anime-p-\(p.id)", title: p.title, query: q { $0.studios = p.studios }))
        }
        rows.append(CatalogRow(id: "anime-ghibli", title: "Studio Ghibli",
                               query: CatalogQuery(itemTypes: ["Movie", "Series"], studios: ["Studio Ghibli"],
                                                   sortBy: "PremiereDate,SortName")))
        for g in GenreGroup.all where animeGenreTitles.contains(g.title) {
            rows.append(CatalogRow(id: "anime-g-\(g.title)", title: g.title, query: q {
                $0.genres = g.names + (g.title == "Fantasy" ? ["Sci-Fi & Fantasy"] : [])
                $0.sortBy = "PremiereDate,SortName"; $0.minCommunityRating = 6.5
                $0.knownTitlesOnly = true; $0.releasedOnly = true
            }))
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
