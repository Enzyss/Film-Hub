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

    public func playbackInfo(itemId: String, startTicks: Int64?, mediaSourceId: String? = nil,
                             maxBitrate: Int = 120_000_000) async throws -> PlaybackInfoResponse {
        let uid = try requireUser()
        let body = PlaybackInfoRequest(
            userId: uid,
            deviceProfile: .apple(maxBitrate: maxBitrate),
            startTimeTicks: startTicks,
            mediaSourceId: mediaSourceId,
            maxStreamingBitrate: maxBitrate
        )
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
