import XCTest
@testable import JellyCore

final class TicksTests: XCTestCase {
    func testRoundTrip() {
        XCTAssertEqual(Ticks.fromSeconds(1.5), 15_000_000)
        XCTAssertEqual(Ticks.toSeconds(36_000_000_000), 3600)
        XCTAssertEqual(Ticks.fromSeconds(-3), 0)
        XCTAssertEqual(Ticks.fromSeconds(.nan), 0)
    }

    func testClock() {
        XCTAssertEqual(Ticks.clock(65), "1:05")
        XCTAssertEqual(Ticks.clock(3723), "1:02:03")
        XCTAssertEqual(Ticks.clock(.infinity), "0:00")
    }

    func testDuration() {
        XCTAssertEqual(Ticks.duration(Ticks.fromSeconds(6120)), "1 h 42 min")
        XCTAssertEqual(Ticks.duration(Ticks.fromSeconds(2520)), "42 min")
    }
}

final class ServerAddressTests: XCTestCase {
    func testExplicitScheme() {
        XCTAssertEqual(ServerAddress.candidates(from: " https://x.com/jf/ ").map(\.absoluteString), ["https://x.com/jf"])
    }

    func testDomainTriesHttpsFirst() {
        XCTAssertEqual(ServerAddress.candidates(from: "jelly.example.com").map(\.absoluteString),
                       ["https://jelly.example.com", "http://jelly.example.com"])
    }

    func testLanTriesHttpFirst() {
        XCTAssertEqual(ServerAddress.candidates(from: "192.168.1.5:8096").map(\.absoluteString),
                       ["http://192.168.1.5:8096", "https://192.168.1.5:8096"])
    }

    func testGarbage() {
        XCTAssertTrue(ServerAddress.candidates(from: "").isEmpty)
        XCTAssertTrue(ServerAddress.candidates(from: "not a url").isEmpty)
    }
}

final class DecodingTests: XCTestCase {
    func testDecodesPascalCaseItem() throws {
        let json = """
        {"Items":[{"Id":"abc","Name":"Pilot","Type":"Episode","SeriesName":"Show",
          "IndexNumber":5,"ParentIndexNumber":2,"RunTimeTicks":36000000000,
          "ImageTags":{"Primary":"t1"},"BackdropImageTags":["b1"],
          "UserData":{"PlaybackPositionTicks":18000000000,"PlayedPercentage":50.0,"Played":false}}],
         "TotalRecordCount":1}
        """.data(using: .utf8)!
        let result = try JellyfinCoding.decoder().decode(QueryResult<BaseItem>.self, from: json)
        let item = try XCTUnwrap(result.items?.first)
        XCTAssertEqual(item.id, "abc")
        XCTAssertEqual(item.displayTitle, "Show")
        XCTAssertEqual(item.displaySubtitle, "S2 · E5 · Pilot")
        XCTAssertEqual(item.resumeSeconds, 1800)
        XCTAssertEqual(item.progress ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(item.imageTag("Primary"), "t1")
        XCTAssertEqual(item.backdropImageTags, ["b1"])
    }

    func testPlayedItemWithoutPositionStartsFromZero() throws {
        let json = #"{"Id":"m","UserData":{"PlaybackPositionTicks":0,"Played":true}}"#.data(using: .utf8)!
        let item = try JellyfinCoding.decoder().decode(BaseItem.self, from: json)
        XCTAssertEqual(item.resumeSeconds, 0)
    }

    /// Real answer from the user's server: an episode being watched again is
    /// "Played" and still has its position (4:50). It must resume there.
    func testRewatchedEpisodeResumes() throws {
        let json = #"{"Id":"f725","Type":"Episode","SeriesId":"b32a","RunTimeTicks":18450880000,"UserData":{"PlayedPercentage":15.75,"PlaybackPositionTicks":2906239999,"PlayCount":2,"Played":true}}"#.data(using: .utf8)!
        let item = try JellyfinCoding.decoder().decode(BaseItem.self, from: json)
        XCTAssertEqual(item.resumeSeconds, 290.6, accuracy: 0.1)
    }

    /// The next-episode answer as the user's server sends it (trimmed).
    func testDecodesNextEpisodeAnswer() throws {
        let json = """
        {"Items":[{"Name":"Valerie è a casa da sola","Id":"f725","Container":"mkv","RunTimeTicks":18450880000,
          "IndexNumber":6,"ParentIndexNumber":3,"IsFolder":false,"Type":"Episode",
          "UserData":{"PlayedPercentage":15.7,"PlaybackPositionTicks":2906239999,"PlayCount":2,"IsFavorite":false,
                      "LastPlayedDate":"2026-11-03T22:26:26.1767519Z","Played":true,"Key":"7538","ItemId":"f725"},
          "SeriesName":"The Comeback","SeriesId":"b32a","SeasonId":"008e","SeriesPrimaryImageTag":"c9dc",
          "ImageTags":{"Primary":"2f4b"},
          "ImageBlurHashes":{"Primary":{"2f4b":"W[I}Y9"},"Thumb":{"c9dc":"W}N,"}},
          "ParentThumbItemId":"b32a","ParentThumbImageTag":"c9dc","LocationType":"FileSystem","MediaType":"Video"},
         {"Name":"Valerie a caccia di verità","Id":"b149","Type":"Episode","IndexNumber":7,"ParentIndexNumber":3,
          "SeriesId":"b32a","UserData":{"PlaybackPositionTicks":0,"Played":true}}],
         "TotalRecordCount":12,"StartIndex":0}
        """.data(using: .utf8)!
        let result = try JellyfinCoding.decoder().decode(QueryResult<BaseItem>.self, from: json)
        XCTAssertEqual(result.items?.map(\.id), ["f725", "b149"])
        XCTAssertEqual(result.items?.last?.episodeLabel, "S3 · E7")
    }

    func testDecodesPlaybackInfo() throws {
        let json = """
        {"MediaSources":[{"Id":"ms1","Container":"mkv","SupportsDirectPlay":false,
          "TranscodingUrl":"/videos/x/master.m3u8?ApiKey=k","DefaultAudioStreamIndex":1,
          "MediaStreams":[{"Type":"Video","Codec":"hevc","Index":0},
                          {"Type":"Audio","Codec":"dts","Index":1}]}],
         "PlaySessionId":"ps1"}
        """.data(using: .utf8)!
        let info = try JellyfinCoding.decoder().decode(PlaybackInfoResponse.self, from: json)
        XCTAssertEqual(info.playSessionId, "ps1")
        let src = try XCTUnwrap(info.mediaSources?.first)
        XCTAssertEqual(src.transcodingUrl, "/videos/x/master.m3u8?ApiKey=k")
        XCTAssertEqual(src.defaultAudioStream?.codec, "dts")
    }

    func testEncodesPascalCase() throws {
        let r = PlaybackReport(itemId: "i", mediaSourceId: "m", playSessionId: "p",
                               positionTicks: 10, isPaused: true, playMethod: "DirectPlay")
        let obj = try JSONSerialization.jsonObject(with: JellyfinCoding.encoder().encode(r)) as! [String: Any]
        XCTAssertEqual(obj["ItemId"] as? String, "i")
        XCTAssertEqual(obj["PlaySessionId"] as? String, "p")
        XCTAssertEqual(obj["PositionTicks"] as? Int, 10)
        XCTAssertEqual(obj["IsPaused"] as? Bool, true)
    }

    func testDeviceProfileKeys() throws {
        let body = PlaybackInfoRequest(userId: "u", deviceProfile: .apple(), startTimeTicks: 5,
                                       mediaSourceId: nil, maxStreamingBitrate: 1)
        let obj = try JSONSerialization.jsonObject(with: JellyfinCoding.encoder().encode(body)) as! [String: Any]
        let profile = try XCTUnwrap(obj["DeviceProfile"] as? [String: Any])
        let tp = try XCTUnwrap((profile["TranscodingProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(tp["Protocol"] as? String, "hls")
        XCTAssertNotNil(profile["DirectPlayProfiles"])
        XCTAssertEqual(obj["EnableDirectPlay"] as? Bool, true)
    }
}

final class APITests: XCTestCase {
    let api = JellyfinAPI(
        baseURL: URL(string: "https://x.com/jf/")!,
        client: ClientInfo(name: "Film Hub", version: "1.0", deviceName: "iPhone", deviceId: "dev1"),
        token: "tok", userId: "u1"
    )

    func testAuthorizationHeader() {
        XCTAssertEqual(api.authorizationHeader,
                       #"MediaBrowser Client="Film Hub", Device="iPhone", DeviceId="dev1", Version="1.0", Token="tok""#)
    }

    func testStaticStreamURL() throws {
        let url = try XCTUnwrap(api.staticStreamURL(itemId: "i1", mediaSourceId: "m1", playSessionId: "p1", fileExtension: "mp4"))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://x.com/jf/Videos/i1/stream.mp4?static=true"))
        XCTAssertTrue(url.absoluteString.contains("api_key=tok"))
        XCTAssertTrue(url.absoluteString.contains("mediaSourceId=m1"))
    }

    func testTranscodeURL() {
        XCTAssertEqual(api.transcodeURL("/videos/i/master.m3u8?ApiKey=k")?.absoluteString,
                       "https://x.com/jf/videos/i/master.m3u8?ApiKey=k")
        XCTAssertEqual(api.transcodeURL("/videos/i/master.m3u8?a=1")?.absoluteString,
                       "https://x.com/jf/videos/i/master.m3u8?a=1&api_key=tok")
        XCTAssertNil(api.transcodeURL(nil))
    }
}

final class DeciderTests: XCTestCase {
    func source(container: String, video: String, tag: String? = nil, audio: String?,
                serverSays: Bool? = true) -> MediaSource {
        var streams = [MediaStream(type: "Video", codec: video, codecTag: tag, index: 0)]
        if let audio { streams.append(MediaStream(type: "Audio", codec: audio, index: 1)) }
        return MediaSource(id: "m", container: container, supportsDirectPlay: serverSays,
                           defaultAudioStreamIndex: audio == nil ? nil : 1, mediaStreams: streams)
    }

    func testCompatibility() {
        XCTAssertTrue(PlaybackDecider.isAppleCompatible(source(container: "mp4", video: "h264", audio: "aac")))
        XCTAssertTrue(PlaybackDecider.isAppleCompatible(source(container: "mov,mp4,m4a,3gp", video: "hevc", tag: "hvc1", audio: "eac3")))
        XCTAssertFalse(PlaybackDecider.isAppleCompatible(source(container: "mkv", video: "h264", audio: "aac")))
        XCTAssertFalse(PlaybackDecider.isAppleCompatible(source(container: "mp4", video: "hevc", tag: "hev1", audio: "aac")))
        XCTAssertFalse(PlaybackDecider.isAppleCompatible(source(container: "mp4", video: "h264", audio: "dts")))
        XCTAssertFalse(PlaybackDecider.isAppleCompatible(source(container: "mp4", video: "h264", audio: "aac", serverSays: false)))
        XCTAssertTrue(PlaybackDecider.isAppleCompatible(source(container: "mp4", video: "h264", audio: nil)))
    }

    func testAppleExtension() {
        XCTAssertEqual(PlaybackDecider.appleExtension(for: source(container: "mov,mp4,m4a", video: "h264", audio: nil)), "mov")
    }

    func testRouteOrder() {
        let a = URL(string: "https://s/a.mp4")!, s = URL(string: "https://s/s")!, t = URL(string: "https://s/t.m3u8")!
        XCTAssertEqual(PlaybackDecider.routes(appleCompatible: true, appleStaticURL: a, staticURL: s, transcodeURL: t, preference: .automatic),
                       [.appleDirect(a), .vlcDirect(s), .appleTranscode(t)])
        XCTAssertEqual(PlaybackDecider.routes(appleCompatible: false, appleStaticURL: a, staticURL: s, transcodeURL: nil, preference: .automatic),
                       [.vlcDirect(s)])
        XCTAssertEqual(PlaybackDecider.routes(appleCompatible: true, appleStaticURL: a, staticURL: s, transcodeURL: t, preference: .alwaysVLC),
                       [.vlcDirect(s), .appleTranscode(t)])
        XCTAssertEqual(PlaybackDecider.routes(appleCompatible: false, appleStaticURL: a, staticURL: s, transcodeURL: t, preference: .preferApple),
                       [.appleTranscode(t), .vlcDirect(s)])
    }
}

/// A fake server that can be switched off.
final class FakeTransport: ProgressTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _online = true
    private var _reports: [(ReportKind, PlaybackReport)] = []

    var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }
    var reports: [(ReportKind, PlaybackReport)] { lock.withLock { _reports } }
    var stopped: [PlaybackReport] { reports.filter { $0.0 == .stopped }.map(\.1) }

    private func hit(_ kind: ReportKind, _ r: PlaybackReport) throws {
        try lock.withLock {
            guard _online else { throw JellyfinError.network("offline") }
            _reports.append((kind, r))
        }
    }

    func reportStart(_ r: PlaybackReport) async throws { try hit(.start, r) }
    func reportProgress(_ r: PlaybackReport) async throws { try hit(.progress, r) }
    func reportStopped(_ r: PlaybackReport) async throws { try hit(.stopped, r) }
}

final class ProgressSyncTests: XCTestCase {
    var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("pending.json")
    }

    func report(_ ticks: Int64) -> PlaybackReport {
        PlaybackReport(itemId: "movie", mediaSourceId: "m", playSessionId: "p",
                       positionTicks: ticks, isPaused: false, playMethod: "DirectPlay")
    }

    func testOnlineReportLeavesNothingPending() async {
        let fake = FakeTransport()
        let sync = ProgressSync(fileURL: file)
        await sync.setTransport(fake)
        let ok = await sync.report(.progress, report(100), runTimeTicks: 1000)
        XCTAssertTrue(ok)
        let pending = await sync.pendingItems
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(fake.reports.count, 1)
    }

    func testOfflineProgressSurvivesRestartAndFlushes() async {
        let fake = FakeTransport()
        fake.online = false
        let sync = ProgressSync(fileURL: file)
        await sync.setTransport(fake)
        let ok = await sync.report(.progress, report(400), runTimeTicks: 1000)
        XCTAssertFalse(ok)

        // The app is killed and relaunched: a new instance reads the file.
        let relaunched = ProgressSync(fileURL: file)
        let pending = await relaunched.pendingItems
        XCTAssertEqual(pending.map(\.positionTicks), [400])

        await relaunched.setTransport(fake)
        await relaunched.flush()  // still offline
        let stillPending = await relaunched.pendingItems
        XCTAssertEqual(stillPending.count, 1)

        fake.online = true
        await relaunched.flush()
        // Replayed as a "stopped" report: the path the real server accepts.
        XCTAssertEqual(fake.stopped.count, 1)
        XCTAssertEqual(fake.stopped.first?.positionTicks, 400)
        XCTAssertEqual(fake.stopped.first?.mediaSourceId, "m")
        XCTAssertEqual(fake.stopped.first?.isPaused, true)
        let after = await relaunched.pendingItems
        XCTAssertTrue(after.isEmpty)
        let reread = await ProgressSync(fileURL: file).pendingItems
        XCTAssertTrue(reread.isEmpty)
    }

    func testOlderPositionNeverOverwritesNewer() async {
        let sync = ProgressSync(fileURL: file)
        let now = Date()
        await sync.record(itemId: "movie", positionTicks: 900, runTimeTicks: nil, at: now)
        await sync.record(itemId: "movie", positionTicks: 100, runTimeTicks: nil, at: now.addingTimeInterval(-60))
        let pending = await sync.pendingItems
        XCTAssertEqual(pending.map(\.positionTicks), [900])
    }

    func testFinishedFlushesItsRealPosition() async {
        let fake = FakeTransport()
        let sync = ProgressSync(fileURL: file)
        await sync.record(itemId: "movie", positionTicks: 950, runTimeTicks: 1000)
        let pending = await sync.pendingItems
        XCTAssertEqual(pending.first?.finished, true)
        await sync.setTransport(fake)
        await sync.flush()
        // The server marks it watched by itself past 90%.
        XCTAssertEqual(fake.stopped.first?.positionTicks, 950)
    }

    func testFlushSkipsTheItemPlayingNow() async {
        let fake = FakeTransport()
        fake.online = false
        let sync = ProgressSync(fileURL: file)
        await sync.setTransport(fake)
        await sync.report(.progress, report(300), runTimeTicks: 1000)  // fails, stays pending
        fake.online = true
        await sync.flush()
        XCTAssertTrue(fake.stopped.isEmpty, "a replayed stop would end the live session")
        await sync.report(.stopped, report(320), runTimeTicks: 1000)
        let pending = await sync.pendingItems
        XCTAssertTrue(pending.isEmpty)
    }

    func testStartAtZeroIsNotRecorded() async {
        let sync = ProgressSync(fileURL: file)
        await sync.report(.start, report(0), runTimeTicks: 1000)
        let pending = await sync.pendingItems
        XCTAssertTrue(pending.isEmpty)
    }
}

final class CatalogTests: XCTestCase {
    func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    func testQueryItems() {
        let q = CatalogQuery(itemTypes: ["Movie"], genres: ["Commedia", "Comedy"], studios: ["Netflix"],
                             sortBy: "Random", unplayedOnly: true, minCommunityRating: 7)
        let items = q.queryItems(userId: "u", startIndex: 24, limit: 24)
        XCTAssertEqual(value(items, "genres"), "Commedia|Comedy")
        XCTAssertEqual(value(items, "studios"), "Netflix")
        XCTAssertEqual(value(items, "isPlayed"), "false")
        XCTAssertEqual(value(items, "startIndex"), "24")
        XCTAssertEqual(value(items, "recursive"), "true")
        XCTAssertFalse(value(items, "fields")!.contains("MediaSources"))
    }

    func testRowsPerTab() {
        let movies = Catalog.rows(for: .movies)
        XCTAssertEqual(movies.first?.title, "Aggiunti di recente")
        XCTAssertTrue(movies.contains { $0.title == "Netflix" })
        XCTAssertTrue(movies.contains { $0.title == "Commedia" })
        XCTAssertEqual(Set(movies.map(\.id)).count, movies.count, "row ids must be unique")
        let docs = Catalog.rows(for: .documentaries)
        XCTAssertTrue(docs.allSatisfy { !$0.query.itemTypes.isEmpty })
        let series = Catalog.rows(for: .series)
        XCTAssertTrue(series.allSatisfy { $0.query.itemTypes == ["Series"] })
    }

    func testDeduplicatesHDAnd4K() throws {
        let json = """
        [{"Id":"a","Name":"Matrix","Type":"Movie","ProductionYear":1999,"ProviderIds":{"Tmdb":"603"}},
         {"Id":"b","Name":"Matrix","Type":"Movie","ProductionYear":1999,"ProviderIds":{"Tmdb":"603"}},
         {"Id":"c","Name":"Matrix Reloaded","Type":"Movie","ProductionYear":2003,"ProviderIds":{"Tmdb":"604"}},
         {"Id":"d","Name":"Senza id","Type":"Movie","ProductionYear":2001},
         {"Id":"e","Name":"senza ID","Type":"Movie","ProductionYear":2001}]
        """.data(using: .utf8)!
        let items = try JellyfinCoding.decoder().decode([BaseItem].self, from: json)
        XCTAssertEqual(items[0].providerId("Tmdb"), "603")
        XCTAssertEqual(items.deduplicated().map(\.id), ["a", "c", "d"])
    }

    func testLabels() throws {
        let json = #"{"Id":"s","Type":"Series","ProductionYear":2008,"ChildCount":5,"CommunityRating":8.94,"CriticRating":96}"#
        let item = try JellyfinCoding.decoder().decode(BaseItem.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(item.metaLine, "2008 · 5 stagioni")
        XCTAssertEqual(item.ratingLabel, "★ 8.9")
        XCTAssertEqual(item.criticLabel, "96%")
    }
}

final class TracksTests: XCTestCase {
    // Like "Matrix" on the user's server: video 0, (1 other), audio eng 2 / ita 3,
    // subtitles eng PGS 4, ita srt 5 (forced), ita srt 6.
    let source = MediaSource(id: "m", container: "mkv", defaultAudioStreamIndex: 2, mediaStreams: [
        MediaStream(type: "Video", codec: "h264", index: 0),
        MediaStream(type: "Attachment", index: 1),
        MediaStream(type: "Audio", codec: "aac", index: 2, language: "eng"),
        MediaStream(type: "Audio", codec: "ac3", index: 3, language: "ita"),
        MediaStream(type: "Subtitle", codec: "PGSSUB", index: 4, language: "eng"),
        MediaStream(type: "Subtitle", codec: "subrip", index: 5, language: "ita", title: "Forced"),
        MediaStream(type: "Subtitle", codec: "subrip", index: 6, language: "ita"),
    ])

    func testItalianAudioNoSubtitlesShowsForcedOnly() {
        let c = Tracks.defaultChoice(for: source, audio: .italian, subtitles: .off)
        XCTAssertEqual(c.audioIndex, 3)
        XCTAssertEqual(c.subtitleIndex, 5)
    }

    func testEnglishAudioItalianSubtitlesPicksFullOnes() {
        let c = Tracks.defaultChoice(for: source, audio: .english, subtitles: .italian)
        XCTAssertEqual(c.audioIndex, 2)
        XCTAssertEqual(c.subtitleIndex, 6)
    }

    func testOriginalAudioKeepsFileDefault() {
        let c = Tracks.defaultChoice(for: source, audio: .original, subtitles: .off)
        XCTAssertEqual(c.audioIndex, 2)
        XCTAssertNil(c.subtitleIndex)
        XCTAssertFalse(Tracks.needsTrackControl(c, source: source))
    }

    func testVLCPositions() {
        XCTAssertEqual(Tracks.vlcPosition(of: 3, in: Tracks.audio(source)), 1)
        XCTAssertEqual(Tracks.vlcPosition(of: 6, in: Tracks.subtitles(source)), 2)
        XCTAssertNil(Tracks.vlcPosition(of: nil, in: Tracks.audio(source)))
    }

    func testTrackControlDropsAppleDirect() {
        let a = URL(string: "https://s/a.mp4")!, s = URL(string: "https://s/s")!
        XCTAssertEqual(PlaybackDecider.routes(appleCompatible: true, appleStaticURL: a, staticURL: s,
                                              transcodeURL: nil, preference: .automatic, needsTrackControl: true),
                       [.vlcDirect(s)])
    }
}

final class GenreRowTests: XCTestCase {
    func testGenreRowsShowRecentKnownReleases() throws {
        let row = try XCTUnwrap(Catalog.rows(for: .movies).first { $0.title == "Azione" })
        let now = ISO8601DateFormatter().date(from: "2026-11-06T10:00:00Z")!
        let items = row.query.queryItems(userId: "u", startIndex: 0, limit: 20, now: now)
        XCTAssertEqual(items.first { $0.name == "hasTmdbId" }?.value, "true")
        XCTAssertEqual(items.first { $0.name == "maxPremiereDate" }?.value, "2026-11-06")
        XCTAssertEqual(items.first { $0.name == "sortBy" }?.value, "PremiereDate,SortName")
    }
}

final class AnimeTests: XCTestCase {
    // The user's libraries, as /UserViews names them.
    let views: [(name: String, id: String)] = [
        ("Anime", "a1"), ("Anime ENG", "a2"), ("Anime SUB ITA", "a3"),
        ("Hentai ENG", "h1"), ("Hentai ITA", "h2"), ("Film", "f1"), ("Serie TV", "s1"),
    ]

    func testFindsAnimeLibrariesWithoutAdultOnes() {
        let libs = AnimeLibraries.from(views: views)
        XCTAssertEqual(libs.all, ["a1", "a2", "a3"])
        XCTAssertEqual(libs.dubbed, "a1")
        XCTAssertEqual(libs.subbed, "a3")
    }

    func testAnimeRowsReadTheAnimeLibraries() {
        let rows = Catalog.rows(for: .anime, anime: AnimeLibraries.from(views: views))
        XCTAssertEqual(rows.first?.title, "Aggiunti di recente")
        XCTAssertEqual(rows.first?.query.parentIds, ["a1", "a2", "a3"])
        XCTAssertTrue(rows.contains { $0.title == "Crunchyroll" })
        XCTAssertTrue(rows.contains { $0.title == "Commedia" })
        XCTAssertTrue(rows.contains { $0.title == "Doppiati in italiano" && $0.query.parentIds == ["a1"] })
        let films = rows.first { $0.title == "Film anime" }
        XCTAssertEqual(films?.query.itemTypes, ["Movie"])
        XCTAssertTrue(films?.query.studios.contains("Studio Ghibli") == true)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertFalse(rows.contains { $0.query.parentIds.contains("h1") })
    }

    func testWithoutAnimeLibrariesFallsBackToGenre() {
        let rows = Catalog.rows(for: .anime)
        XCTAssertEqual(rows.first?.query.genres, ["Anime"])
        XCTAssertFalse(rows.contains { $0.title == "Doppiati in italiano" })
    }

    func testQueryAddsParentId() {
        let items = CatalogQuery(itemTypes: ["Series"]).queryItems(userId: "u", startIndex: 0, limit: 5, parentId: "a3")
        XCTAssertEqual(items.first { $0.name == "parentId" }?.value, "a3")
    }

    func testInterleaveMixesLibraries() {
        let a = [BaseItem(id: "a1"), BaseItem(id: "a2"), BaseItem(id: "a3")]
        let b = [BaseItem(id: "b1")]
        XCTAssertEqual(CatalogCursor.interleave([a, b]).map(\.id), ["a1", "b1", "a2", "a3"])
    }

    func testCursorFinishes() {
        let q = CatalogQuery(itemTypes: ["Series"], parentIds: ["a1", "a3"])
        var c = CatalogCursor.start
        XCTAssertFalse(c.isFinished(for: q))
        c.exhausted = ["a1", "a3"]
        XCTAssertTrue(c.isFinished(for: q))
    }

    func testVersionLabelsFromFolders() throws {
        let json = """
        [{"Id":"1","Type":"Series","Path":"/Anime/Naruto (2002)"},
         {"Id":"2","Type":"Series","Path":"/AnimeSub/Naruto (2002)"},
         {"Id":"3","Type":"Series","Path":"/AnimeEng/Naruto"},
         {"Id":"4","Type":"Movie","Path":"/Film4K/Matrix (1999)/Matrix.mkv"}]
        """.data(using: .utf8)!
        let items = try JellyfinCoding.decoder().decode([BaseItem].self, from: json)
        XCTAssertEqual(items.map(\.versionLabel), ["Doppiato ITA", "Sub ITA", "Inglese", "4K"])
    }
}

final class PiPRoutingTests: XCTestCase {
    let a = URL(string: "https://s/a.mp4")!, s = URL(string: "https://s/s")!, t = URL(string: "https://s/t.m3u8")!

    func src(video: String = "h264", range: String? = "SDR", audio: String? = "eac3") -> MediaSource {
        var streams = [MediaStream(type: "Video", codec: video, index: 0, videoRangeType: range)]
        if let audio { streams.append(MediaStream(type: "Audio", codec: audio, index: 1)) }
        return MediaSource(id: "m", container: "mkv", defaultAudioStreamIndex: 1, mediaStreams: streams)
    }

    func testQuickRepackaging() {
        XCTAssertTrue(PlaybackDecider.isRepackagedQuickly(src()))
        XCTAssertTrue(PlaybackDecider.isRepackagedQuickly(src(video: "hevc", range: "HDR10", audio: "ac3")))
        XCTAssertFalse(PlaybackDecider.isRepackagedQuickly(src(audio: "dts")))
        XCTAssertFalse(PlaybackDecider.isRepackagedQuickly(src(video: "hevc", range: "DOVIWithHDR10", audio: "eac3")))
        XCTAssertFalse(PlaybackDecider.isRepackagedQuickly(src(video: "mpeg4")))
    }

    func testMKVThatRepackagesGoesToApple() {
        XCTAssertEqual(PlaybackDecider.routes(appleCompatible: false, appleStaticURL: a, staticURL: s, transcodeURL: t,
                                              preference: .automatic, repackagedQuickly: true),
                       [.appleTranscode(t), .vlcDirect(s)])
    }

    func testSubtitlesOrHeavyFilesStayOnVLC() {
        XCTAssertEqual(PlaybackDecider.routes(appleCompatible: false, appleStaticURL: a, staticURL: s, transcodeURL: t,
                                              preference: .automatic, repackagedQuickly: true, subtitlesOn: true),
                       [.vlcDirect(s), .appleTranscode(t)])
        XCTAssertEqual(PlaybackDecider.routes(appleCompatible: false, appleStaticURL: a, staticURL: s, transcodeURL: t,
                                              preference: .automatic, repackagedQuickly: false),
                       [.vlcDirect(s), .appleTranscode(t)])
        XCTAssertEqual(PlaybackDecider.routes(appleCompatible: false, appleStaticURL: a, staticURL: s, transcodeURL: t,
                                              preference: .alwaysVLC, repackagedQuickly: true),
                       [.vlcDirect(s), .appleTranscode(t)])
    }
}
