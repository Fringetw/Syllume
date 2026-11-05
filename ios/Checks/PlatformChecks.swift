import Foundation

enum PlatformChecks {
    static func run() throws {
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
    }

    private static func decode(_ json: String, platform: LibraryPlatform, collection: LibraryCollection) throws -> LibraryPage {
        try PlatformLibrary.decode(Data(json.utf8), platform: platform, collection: collection)
    }
}
