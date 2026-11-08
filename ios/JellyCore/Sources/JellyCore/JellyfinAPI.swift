import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum JellyfinError: LocalizedError, Equatable {
    case invalidAddress
    case unauthorized
    case http(Int)
    case network(String)
    case decoding(String)
    case notLoggedIn

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Indirizzo del server non valido."
        case .unauthorized: return "Utente o password non corretti, oppure la sessione è scaduta."
        case .http(let code): return "Il server ha risposto con un errore (\(code))."
        case .network(let msg): return "Server non raggiungibile: \(msg)"
        case .decoding: return "Risposta del server non riconosciuta."
        case .notLoggedIn: return "Accesso non effettuato."
        }
    }
}

public struct ClientInfo: Sendable, Hashable {
    public var name: String
    public var version: String
    public var deviceName: String
    public var deviceId: String

    public init(name: String, version: String, deviceName: String, deviceId: String) {
        self.name = name
        self.version = version
        self.deviceName = deviceName
        self.deviceId = deviceId
    }
}

/// Body of POST /Sessions/Playing, /Progress and /Stopped.
public struct PlaybackReport: Codable, Sendable, Equatable {
    public var itemId: String
    public var mediaSourceId: String?
    public var playSessionId: String?
    public var positionTicks: Int64
    public var isPaused: Bool
    public var playMethod: String
    public var canSeek: Bool

    public init(itemId: String, mediaSourceId: String?, playSessionId: String?,
                positionTicks: Int64, isPaused: Bool, playMethod: String) {
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.playSessionId = playSessionId
        self.positionTicks = positionTicks
        self.isPaused = isPaused
        self.playMethod = playMethod
        self.canSeek = true
    }
}

/// Body of POST /UserItems/{id}/UserData.
public struct UserDataUpdate: Codable, Sendable, Equatable {
    public var playbackPositionTicks: Int64?
    public var played: Bool?
    public var lastPlayedDate: String?

    public init(playbackPositionTicks: Int64? = nil, played: Bool? = nil, lastPlayedDate: String? = nil) {
        self.playbackPositionTicks = playbackPositionTicks
        self.played = played
        self.lastPlayedDate = lastPlayedDate
    }
}

/// Thin client over the public Jellyfin API (10.9+).
public struct JellyfinAPI: Sendable {
    public let baseURL: URL
    public let client: ClientInfo
    public let token: String?
    public let userId: String?
    private let session: URLSession

    public static let apiTimeout: TimeInterval = 15

    public init(baseURL: URL, client: ClientInfo, token: String? = nil, userId: String? = nil,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.client = client
        self.token = token
        self.userId = userId
        self.session = session
    }

    public func authorized(token: String, userId: String) -> JellyfinAPI {
        JellyfinAPI(baseURL: baseURL, client: client, token: token, userId: userId, session: session)
    }

    // MARK: Header and URLs

    public var authorizationHeader: String {
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: ",", with: " ")
        }
        var parts = [
            "Client=\"\(clean(client.name))\"",
            "Device=\"\(clean(client.deviceName))\"",
            "DeviceId=\"\(clean(client.deviceId))\"",
            "Version=\"\(clean(client.version))\"",
        ]
        if let token { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    var baseString: String {
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public func url(_ path: String, _ query: [URLQueryItem] = []) -> URL? {
        guard var comps = URLComponents(string: baseString + path) else { return nil }
        let items = query.filter { $0.value != nil }
        if !items.isEmpty { comps.queryItems = (comps.queryItems ?? []) + items }
        // "+" is legal in a query but servers read it as a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url
    }

    /// The original file, untouched. Used by both players for direct play.
    public func staticStreamURL(itemId: String, mediaSourceId: String?, playSessionId: String?,
                                fileExtension: String? = nil) -> URL? {
        let path = "/Videos/\(itemId)/stream" + (fileExtension.map { ".\($0)" } ?? "")
        return url(path, [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "deviceId", value: client.deviceId),
            URLQueryItem(name: "playSessionId", value: playSessionId),
            URLQueryItem(name: "api_key", value: token),
        ])
    }

    /// The server's HLS URL from PlaybackInfo (relative), made absolute.
    public func transcodeURL(_ relative: String?) -> URL? {
        guard let relative, !relative.isEmpty else { return nil }
        var s = relative.hasPrefix("http") ? relative : baseString + (relative.hasPrefix("/") ? "" : "/") + relative
        let lower = s.lowercased()
        if let token, !lower.contains("api_key="), !lower.contains("apikey=") {
            s += (s.contains("?") ? "&" : "?") + "api_key=\(token)"
        }
        return URL(string: s)
    }

    public func imageURL(itemId: String, type: String, tag: String?, width: Int) -> URL? {
        url("/Items/\(itemId)/Images/\(type)", [
            URLQueryItem(name: "fillWidth", value: String(width)),
            URLQueryItem(name: "quality", value: "85"),
            URLQueryItem(name: "tag", value: tag),
        ])
    }

    // MARK: Requests

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      body: (any Encodable)? = nil, timeout: TimeInterval = apiTimeout) async throws -> Data {
        guard let url = url(path, query) else { throw JellyfinError.invalidAddress }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JellyfinCoding.encoder().encode(body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as URLError where err.code == .cancelled {
            throw CancellationError()
        } catch {
            throw JellyfinError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.network("nessuna risposta") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw JellyfinError.unauthorized
        default: throw JellyfinError.http(http.statusCode)
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        let data = try await send("GET", path, query: query)
        return try decode(type, data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JellyfinCoding.decoder().decode(type, from: data)
        } catch {
            throw JellyfinError.decoding(String(describing: error))
        }
    }

    private func requireUser() throws -> String {
        guard let userId, token != nil else { throw JellyfinError.notLoggedIn }
        return userId
    }

    // MARK: Endpoints

    public func publicInfo() async throws -> PublicSystemInfo {
        try await get(PublicSystemInfo.self, "/System/Info/Public")
    }

    public func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        struct Body: Encodable { var username: String; var pw: String }
        let data = try await send("POST", "/Users/AuthenticateByName", body: Body(username: username, pw: password))
        return try decode(AuthenticationResult.self, data)
    }

    static let cardFields = "Overview,PrimaryImageAspectRatio"

    public func resumeItems(limit: Int = 30) async throws -> [BaseItem] {
        let uid = try requireUser()
        return try await get(QueryResult<BaseItem>.self, "/UserItems/Resume", [
            URLQueryItem(name: "userId", value: uid),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "mediaTypes", value: "Video"),
            URLQueryItem(name: "fields", value: Self.cardFields),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
            URLQueryItem(name: "enableImageTypes", value: "Primary,Backdrop,Thumb"),
        ]).items ?? []
    }

    public func nextUp(limit: Int = 30) async throws -> [BaseItem] {
        let uid = try requireUser()
        return try await get(QueryResult<BaseItem>.self, "/Shows/NextUp", [
            URLQueryItem(name: "userId", value: uid),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: Self.cardFields),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "enableResumable", value: "false"),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
            URLQueryItem(name: "enableImageTypes", value: "Primary,Backdrop,Thumb"),
        ]).items ?? []
    }

    public func item(id: String) async throws -> BaseItem {
        let uid = try requireUser()
        return try await get(BaseItem.self, "/Items/\(id)", [URLQueryItem(name: "userId", value: uid)])
    }

    // MARK: Catalog

    /// The first page of a query (one row of a tab).
    public func items(_ query: CatalogQuery, limit: Int = 24) async throws -> [BaseItem] {
        try await page(query, cursor: .start, limit: limit).items
    }

    /// One page of a query, and where the next one starts. A query over
    /// several libraries asks each one at the same time and mixes the results.
    public func page(_ query: CatalogQuery, cursor: CatalogCursor, limit: Int) async throws
        -> (items: [BaseItem], next: CatalogCursor) {
        let uid = try requireUser()
        let active = CatalogCursor.keys(for: query).filter { !cursor.exhausted.contains($0) }
        guard !active.isEmpty else { return ([], cursor) }
        let per = max(1, Int((Double(limit) / Double(active.count)).rounded(.up)))
        let lists = try await withThrowingTaskGroup(of: (Int, [BaseItem]).self) { group in
            for (i, key) in active.enumerated() {
                let items = query.queryItems(userId: uid, startIndex: cursor.offsets[key] ?? 0, limit: per,
                                             parentId: key.isEmpty ? nil : key)
                group.addTask {
                    (i, try await self.get(QueryResult<BaseItem>.self, "/Items", items).items ?? [])
                }
            }
            var out = [[BaseItem]](repeating: [], count: active.count)
            for try await (i, list) in group { out[i] = list }
            return out
        }
        var next = cursor
        for (i, key) in active.enumerated() {
            next.offsets[key, default: 0] += lists[i].count
            if lists[i].count < per { next.exhausted.insert(key) }
        }
        return (CatalogCursor.interleave(lists), next)
    }

    static let detailFields = "Overview,Genres,People,Studios,ProviderIds,Taglines,ChildCount,MediaSources,PrimaryImageAspectRatio"

    /// Everything the title page shows, in one call (~0.5 s on the user's server).
    public func detail(id: String) async throws -> BaseItem {
        let uid = try requireUser()
        return try await get(BaseItem.self, "/Items/\(id)", [
            URLQueryItem(name: "userId", value: uid),
            URLQueryItem(name: "fields", value: Self.detailFields),
        ])
    }

    public func seasons(seriesId: String) async throws -> [BaseItem] {
        let uid = try requireUser()
        return try await get(QueryResult<BaseItem>.self, "/Shows/\(seriesId)/Seasons", [
            URLQueryItem(name: "userId", value: uid),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "fields", value: "ChildCount"),
        ]).items ?? []
    }

    public func episodes(seriesId: String, seasonId: String) async throws -> [BaseItem] {
        let uid = try requireUser()
        return try await get(QueryResult<BaseItem>.self, "/Shows/\(seriesId)/Episodes", [
            URLQueryItem(name: "userId", value: uid),
            URLQueryItem(name: "seasonId", value: seasonId),
            URLQueryItem(name: "fields", value: "Overview,PrimaryImageAspectRatio"),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
            URLQueryItem(name: "enableImageTypes", value: "Primary,Thumb"),
        ]).items ?? []
    }

    /// The next episode to watch in one series.
    public func nextUp(seriesId: String) async throws -> BaseItem? {
        let uid = try requireUser()
        return try await get(QueryResult<BaseItem>.self, "/Shows/NextUp", [
            URLQueryItem(name: "userId", value: uid),
            URLQueryItem(name: "seriesId", value: seriesId),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "enableResumable", value: "true"),
            URLQueryItem(name: "enableUserData", value: "true"),
        ]).items?.first
    }

    public func similar(id: String, limit: Int = 16) async throws -> [BaseItem] {
        let uid = try requireUser()
        let items = try await get(QueryResult<BaseItem>.self, "/Items/\(id)/Similar", [
            URLQueryItem(name: "userId", value: uid),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: CatalogQuery.cardFields),
        ]).items ?? []
        return items.filter { $0.id != id }.deduplicated()
    }

    /// Other copies of the same film in other libraries (HD, 4K...).
    /// Other copies of the same title in other libraries: HD and 4K films,
    /// dubbed and subtitled anime.
    public func versions(of item: BaseItem) async throws -> [BaseItem] {
        guard item.isMovie || item.isSeries, let name = item.name, !name.isEmpty else { return [item] }
        let uid = try requireUser()
        var q: [URLQueryItem] = [
            URLQueryItem(name: "userId", value: uid),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: item.isMovie ? "Movie" : "Series"),
            URLQueryItem(name: "searchTerm", value: name),
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "fields", value: item.isMovie ? "ProviderIds,MediaSources,Path" : "ProviderIds,Path"),
            URLQueryItem(name: "enableUserData", value: "true"),
        ]
        if let y = item.productionYear { q.append(URLQueryItem(name: "years", value: String(y))) }
        let found = try await get(QueryResult<BaseItem>.self, "/Items", q).items ?? []
        let same = found.filter { $0.dedupeKey == item.dedupeKey }
        return same.isEmpty ? [item] : same
    }

    /// Title search across films and series (~0.8 s on the user's server).
    public func search(_ term: String, limit: Int = 40) async throws -> [BaseItem] {
        try await items(CatalogQuery(itemTypes: ["Movie", "Series"], sortBy: "SortName", descending: false,
                                     searchTerm: term, extraFields: ["ParentId", "Studios"]),
                        limit: limit).deduplicated()
    }

    /// The libraries in the user's home screen (name, id, kind).
    public func views() async throws -> [BaseItem] {
        let uid = try requireUser()
        return try await get(QueryResult<BaseItem>.self, "/UserViews", [URLQueryItem(name: "userId", value: uid)]).items ?? []
    }

    /// The folder id the series of a library report as their ParentId.
    public func folderId(ofLibrary id: String) async throws -> String? {
        let uid = try requireUser()
        return try await get(QueryResult<BaseItem>.self, "/Items", [
            URLQueryItem(name: "userId", value: uid),
            URLQueryItem(name: "parentId", value: id),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Series,Movie"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fields", value: "ParentId"),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
        ]).items?.first?.parentId
    }

    public func markPlayed(itemId: String, played: Bool) async throws {
        let uid = try requireUser()
        _ = try await send(played ? "POST" : "DELETE", "/UserPlayedItems/\(itemId)",
                           query: [URLQueryItem(name: "userId", value: uid)])
    }

    /// An external or text subtitle as a file VLC can load.
    public func subtitleURL(itemId: String, mediaSourceId: String, index: Int, format: String = "srt") -> URL? {
        url("/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(index)/0/Stream.\(format)", [
            URLQueryItem(name: "api_key", value: token),
        ])
    }

    public func personImageURL(_ person: Person, width: Int) -> URL? {
        guard let tag = person.primaryImageTag else { return nil }
        return imageURL(itemId: person.id, type: "Primary", tag: tag, width: width)
    }

    // MARK: Playback

    public func playbackInfo(itemId: String, startTicks: Int64?, mediaSourceId: String? = nil,
                             choice: TrackChoice? = nil,
                             maxBitrate: Int = 120_000_000) async throws -> PlaybackInfoResponse {
        let uid = try requireUser()
        var body = PlaybackInfoRequest(
            userId: uid,
            deviceProfile: .apple(maxBitrate: maxBitrate),
            startTimeTicks: startTicks,
            mediaSourceId: mediaSourceId,
            maxStreamingBitrate: maxBitrate
        )
        body.audioStreamIndex = choice?.audioIndex
        body.subtitleStreamIndex = choice?.subtitleIndex ?? (choice == nil ? nil : -1)
        let data = try await send("POST", "/Items/\(itemId)/PlaybackInfo",
                                  query: [URLQueryItem(name: "userId", value: uid)], body: body)
        return try decode(PlaybackInfoResponse.self, data)
    }

    public func reportStart(_ r: PlaybackReport) async throws {
        _ = try await send("POST", "/Sessions/Playing", body: r)
    }

    public func reportProgress(_ r: PlaybackReport) async throws {
        _ = try await send("POST", "/Sessions/Playing/Progress", body: r)
    }

    public func reportStopped(_ r: PlaybackReport) async throws {
        _ = try await send("POST", "/Sessions/Playing/Stopped", body: r)
    }

    public func saveUserData(itemId: String, update: UserDataUpdate) async throws {
        let uid = try requireUser()
        _ = try await send("POST", "/UserItems/\(itemId)/UserData",
                           query: [URLQueryItem(name: "userId", value: uid)], body: update)
    }
}
