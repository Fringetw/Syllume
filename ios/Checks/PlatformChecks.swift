import Foundation

enum PlatformChecks {
    @MainActor static func run() async throws {
        let client = "0123456789abcdef0123456789abcdef"
        let redirect = try LibraryPlatform.spotify.redirect(clientID: client)
        precondition(redirect.absoluteString == "folia-spotify://callback")
        precondition((try? LibraryPlatform.spotify.redirect(clientID: "bad")) == nil)
        let google = try LibraryPlatform.youtube.redirect(clientID: "123-test.apps.googleusercontent.com")
        precondition(google.absoluteString == "com.googleusercontent.apps.123-test:/oauth2redirect")
        precondition((try? LibraryPlatform.youtube.redirect(clientID: "https://evil.example")) == nil)
        let config = GoogleClientConfiguration(clientID: "123-test.apps.googleusercontent.com",
            registeredBundleID: "org.folia.community.ios", bundleID: "org.folia.community.ios",
            schemes: ["folia-spotify", "com.googleusercontent.apps.123-test"])
        precondition(config.isReady && config.acceptsCredential(clientID: "123-test.apps.googleusercontent.com"))
        precondition(!config.acceptsCredential(clientID: "456-old.apps.googleusercontent.com"))
        precondition(GoogleClientConfiguration(clientID: nil, registeredBundleID: nil,
            bundleID: "org.folia.community.ios", schemes: []).issue == .missing)
        precondition(GoogleClientConfiguration(clientID: "bad", registeredBundleID: "org.folia.community.ios",
            bundleID: "org.folia.community.ios", schemes: []).issue == .invalidClient)
        precondition(GoogleClientConfiguration(clientID: config.clientID, registeredBundleID: "org.folia.community.ios",
            bundleID: "org.folia.community.ios.resigned", schemes: ["com.googleusercontent.apps.123-test"]).issue == .bundleMismatch)
        precondition(GoogleClientConfiguration(clientID: config.clientID, registeredBundleID: "org.folia.community.ios",
            bundleID: "org.folia.community.ios", schemes: []).issue == .missingCallback)
        let sourceID = "org.folia.community.ios"
        let signedID = sourceID + ".TESTTEAM01"
        let schemes = ["com.googleusercontent.apps.123-test"]
        precondition(GoogleClientConfiguration(clientID: config.clientID, registeredBundleID: signedID,
            bundleID: sourceID, schemes: schemes).issue == .bundleMismatch)
        precondition(GoogleClientConfiguration(clientID: config.clientID, registeredBundleID: signedID,
            bundleID: signedID, schemes: schemes).isReady)
        precondition(GoogleClientConfiguration(clientID: config.clientID, registeredBundleID: signedID,
            bundleID: signedID + ".TESTTEAM01", schemes: schemes).issue == .bundleMismatch)
        let callback = URL(string: "folia-spotify://callback?code=auth-code&state=nonce")!
        let code = try OAuthCallback.code(from: callback, expected: redirect, state: "nonce")
        precondition(code == "auth-code")
        for value in [
            "folia-spotify://callback?code=auth-code&state=wrong",
            "folia-spotify://other?code=auth-code&state=nonce",
            "folia-spotify://callback?code=a&code=b&state=nonce",
            "folia-spotify://callback?code=a&state=nonce&state=nonce",
            "folia-spotify://callback?error=access_denied&state=nonce"
        ] {
            precondition((try? OAuthCallback.code(from: URL(string: value)!, expected: redirect, state: "nonce")) == nil)
        }
        let endpoint = try PlatformLibrary.endpoint(platform: .spotify, collection: .playlist("abc"), cursor: "20")
        precondition(endpoint.path == "/v1/playlists/abc/items")
        precondition(URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "offset", value: "20")) == true)
        precondition((try? PlatformLibrary.endpoint(platform: .spotify, collection: .playlist("../../me"), cursor: nil)) == nil)
        precondition((try? PlatformLibrary.endpoint(platform: .spotify, collection: .liked, cursor: "https://evil.example")) == nil)

        let oldPage = try decode(#"{"items":[{"track":{"id":"song1","name":"First","artists":[{"name":"Artist"}]}},null,{"track":null}],"next":"https://api.spotify.com/v1/me/tracks?offset=20"}"#,
                                 platform: .spotify, collection: .liked)
        precondition(oldPage.entries.count == 1 && oldPage.entries[0].subtitle == "Artist")
        precondition(oldPage.next == "20")
        let newPage = try decode(#"{"offset":20,"items":[{"item":{"id":"song1","type":"track","name":"First"}},{"item":{"id":"song1","name":"First"}},{"item":{"id":"ep1","type":"episode","name":"Episode"}}],"next":null}"#,
                                 platform: .spotify, collection: .playlist("p"))
        precondition(newPage.entries.count == 2 && Set(newPage.entries.map(\.id)).count == 2)
        precondition(newPage.entries[0].url.absoluteString == "https://open.spotify.com/track/song1")
        let hostile = try decode(#"{"items":[],"next":"https://evil.example/?offset=100"}"#, platform: .spotify, collection: .playlists)
        precondition(hostile.next == nil)
        let playlist = try decode(#"{"items":[{"id":"p1","name":"My playlist","owner":{"display_name":"Owner"}}],"next":null}"#,
                                  platform: .spotify, collection: .playlists)
        precondition(playlist.entries[0].url.absoluteString == "https://open.spotify.com/playlist/p1")
        let youtube = try decode(#"{"items":[{"id":"entry1","snippet":{"title":"Song","videoOwnerChannelTitle":"Singer","resourceId":{"videoId":"abc_123-456"}}},{"id":"entry2","snippet":{"title":"Song","resourceId":{"videoId":"abc_123-456"}}},{"snippet":{"title":"Private video","resourceId":{"videoId":"private"}}}],"nextPageToken":"a+b/="}"#,
                                 platform: .youtube, collection: .playlist("PLtest"))
        precondition(youtube.entries.count == 2 && Set(youtube.entries.map(\.id)).count == 2)
        precondition(youtube.entries[0].url.absoluteString == "https://music.youtube.com/watch?v=abc_123-456")
        let next = try PlatformLibrary.endpoint(platform: .youtube, collection: .playlist("PLtest"), cursor: youtube.next)
        precondition(URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "pageToken", value: "a+b/=")) == true)
        let likes = try decode(#"{"items":[{"id":"video1","snippet":{"title":"Liked","channelTitle":"Channel"}}]}"#,
                               platform: .youtube, collection: .liked)
        precondition(likes.entries[0].id == "video1")
        print("PASS: platform metadata, pagination, duplicate songs, OAuth callbacks, and invalid input")
        try await checkSelectedVideoLookup()
    }

    @MainActor private static func checkSelectedVideoLookup() async throws {
        let videoID = "abc_123-456"
        var time = ContinuousClock().now
        let lookup = SelectedYouTubeVideoLookup { time }
        let played = details(videoID, seconds: 100, embeddable: true)
        let restricted = details(videoID, seconds: 101, embeddable: false)
        let probe = SelectedVideoRequestProbe()

        let previous = Task { try await lookup.details(for: videoID, useCachedMetadata: false) { try await probe.fetch() } }
        await probe.waitUntilStarted()
        let (joined, start) = AsyncStream<Void>.makeStream()
        let selected = Task {
            start.yield(())
            return try await lookup.details(for: videoID, useCachedMetadata: false) { try await probe.fetch() }
        }
        for await _ in joined { break }
        previous.cancel()
        do {
            _ = try await previous.value
            preconditionFailure("A cancelled subscriber received selected-video metadata")
        } catch is CancellationError {}
        probe.finish(played)
        let latest = try await selected.value
        precondition(probe.calls == 1 && latest.status?.allowsEmbeddedPlayback == true,
            "Overlapping playback lookups must share a request, even when one subscriber is cancelled")

        let enriched = try await lookup.details(for: videoID, useCachedMetadata: true) {
            preconditionFailure("Immediately downloading a played song fetched the same metadata again")
        }
        precondition(enriched.duration == 100 && enriched.status == nil)
        let fresh = try await lookup.details(for: videoID, useCachedMetadata: false) { restricted }
        precondition(fresh.status?.allowsEmbeddedPlayback == false,
            "Playback must observe revoked embed availability immediately")

        time = time.advanced(by: .seconds(121))
        let expired = try await lookup.details(for: videoID, useCachedMetadata: true) { played }
        precondition(expired.duration == 100 && expired.status != nil)
        do {
            _ = try await lookup.details(for: videoID, useCachedMetadata: false) { throw DiagnosticProblem(code: .unavailable) }
            preconditionFailure("A failed refresh returned a stale response")
        } catch let problem as DiagnosticProblem { precondition(problem.code == .unavailable) }
        let recovered = try await lookup.details(for: videoID, useCachedMetadata: true) { restricted }
        precondition(recovered.duration == 101 && recovered.status != nil,
            "A failed refresh must not leave old metadata available")

        let oldAccount = SelectedVideoRequestProbe()
        let abandoned = Task { try await lookup.details(for: videoID, useCachedMetadata: false) { try await oldAccount.fetch() } }
        await oldAccount.waitUntilStarted()
        lookup.reset()
        do {
            _ = try await abandoned.value
            preconditionFailure("An account switch left an existing subscriber active")
        } catch is CancellationError {}
        let newAccount = SelectedVideoRequestProbe()
        let signedIn = Task { try await lookup.details(for: videoID, useCachedMetadata: true) { try await newAccount.fetch() } }
        await newAccount.waitUntilStarted()
        oldAccount.finish(restricted)
        newAccount.finish(played)
        let newResult = try await signedIn.value
        precondition(newAccount.calls == 1 && newResult.duration == 100 && newResult.status?.allowsEmbeddedPlayback == true)
        let signedInCache = try await lookup.details(for: videoID, useCachedMetadata: true) {
            preconditionFailure("A late response from the old account invalidated the current metadata")
        }
        precondition(signedInCache.duration == 100 && signedInCache.status == nil)
        print("PASS: selected YouTube video shares requests, expires download metadata, and revalidates embed status per account")
    }

    private static func details(_ id: String, seconds: Int, embeddable: Bool) -> YouTubeVideoDetails {
        YouTubeVideoDetails(id: id, contentDetails: .init(duration: "PT\(seconds)S"), snippet: nil,
                            status: .init(embeddable: embeddable, madeForKids: false))
    }

    @MainActor private final class SelectedVideoRequestProbe {
        private(set) var calls = 0
        private var response: YouTubeVideoDetails?
        private var waiters: [CheckedContinuation<YouTubeVideoDetails, Never>] = []

        func fetch() async throws -> YouTubeVideoDetails {
            calls += 1
            if let response { return response }
            return await withCheckedContinuation { waiters.append($0) }
        }

        func waitUntilStarted() async {
            let deadline = ContinuousClock().now.advanced(by: .seconds(2))
            while calls == 0 && ContinuousClock().now < deadline { await Task.yield() }
            precondition(calls == 1, "Expected a new selected-video request to start")
        }

        func finish(_ value: YouTubeVideoDetails) {
            response = value
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume(returning: value) }
        }
    }

    private static func decode(_ json: String, platform: LibraryPlatform, collection: LibraryCollection) throws -> LibraryPage {
        try PlatformLibrary.decode(Data(json.utf8), platform: platform, collection: collection)
    }
}
