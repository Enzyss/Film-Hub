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

    func testPlayedItemStartsFromZero() throws {
        let json = #"{"Id":"m","UserData":{"PlaybackPositionTicks":500,"Played":true}}"#.data(using: .utf8)!
        let item = try JellyfinCoding.decoder().decode(BaseItem.self, from: json)
        XCTAssertEqual(item.resumeSeconds, 0)
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
    private var _saved: [(String, UserDataUpdate)] = []

    var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }
    var reports: [(ReportKind, PlaybackReport)] { lock.withLock { _reports } }
    var saved: [(String, UserDataUpdate)] { lock.withLock { _saved } }

    private func hit(_ kind: ReportKind, _ r: PlaybackReport) throws {
        try lock.withLock {
            guard _online else { throw JellyfinError.network("offline") }
            _reports.append((kind, r))
        }
    }

    func reportStart(_ r: PlaybackReport) async throws { try hit(.start, r) }
    func reportProgress(_ r: PlaybackReport) async throws { try hit(.progress, r) }
    func reportStopped(_ r: PlaybackReport) async throws { try hit(.stopped, r) }
    func saveUserData(itemId: String, update: UserDataUpdate) async throws {
        try lock.withLock {
            guard _online else { throw JellyfinError.network("offline") }
            _saved.append((itemId, update))
        }
    }
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
        XCTAssertEqual(fake.saved.count, 1)
        XCTAssertEqual(fake.saved.first?.1.playbackPositionTicks, 400)
        XCTAssertNotNil(fake.saved.first?.1.lastPlayedDate)
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

    func testFinishedFlushesAsPlayed() async {
        let fake = FakeTransport()
        let sync = ProgressSync(fileURL: file)
        await sync.record(itemId: "movie", positionTicks: 950, runTimeTicks: 1000)
        await sync.setTransport(fake)
        await sync.flush()
        XCTAssertEqual(fake.saved.first?.1.played, true)
        XCTAssertEqual(fake.saved.first?.1.playbackPositionTicks, 0)
    }

    func testStartAtZeroIsNotRecorded() async {
        let sync = ProgressSync(fileURL: file)
        await sync.report(.start, report(0), runTimeTicks: 1000)
        let pending = await sync.pendingItems
        XCTAssertTrue(pending.isEmpty)
    }
}
