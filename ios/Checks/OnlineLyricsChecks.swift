import Foundation

enum OnlineLyricsChecks {
    private actor Fixture {
        private(set) var requests = 0
        private(set) var cancellations = 0
        var held = true

        func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requests += 1
            for _ in 0..<200 {
                if !held { break }
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch {
                    cancellations += 1
                    throw error
                }
            }
            guard !held else { throw URLError(.timedOut) }
            let url = request.url!
            let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "track_name" })?.value
            let payload: (Int, String) = switch title {
            case "Unavailable": (500, "")
            case "Missing": url.lastPathComponent == "search" ? (200, "[]") : (404, "")
            default: (200, #"{"id":1,"trackName":"Song Title","artistName":"Artist","albumName":"Album","duration":180,"syncedLyrics":"[00:01]First line"}"#)
            }
            return (Data(payload.1.utf8), HTTPURLResponse(url: url, statusCode: payload.0, httpVersion: nil, headerFields: nil)!)
        }

        func setHeld(_ held: Bool) { self.held = held }

        func waitForRequests(_ count: Int) async throws {
            for _ in 0..<200 {
                if requests >= count { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            preconditionFailure("Expected LRCLIB request \(count), saw \(requests)")
        }

        func waitForOrphanCancellation() async throws {
            for _ in 0..<200 {
                if cancellations != 0 { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            preconditionFailure("The last canceled waiter left a network request running")
        }
    }

    static func run() async throws {
        let fixture = Fixture()
        let lyrics = OnlineLyrics(transport: { try await fixture.respond($0) })
        let initial = Task { try await lyrics.exact(title: "Song Title", artist: "Artist", duration: 180) }
        try await fixture.waitForRequests(1)
        initial.cancel()
        do {
            _ = try await initial.value
            preconditionFailure("The canceled provisional lookup returned a result")
        } catch is CancellationError {}

        let actual = Task { try await lyrics.exact(title: "Song Title", artist: "Artist", duration: 180) }
        try await Task.sleep(for: .milliseconds(60))
        await fixture.setHeld(false)
        let active = try await actual.value
        let cached = try await lyrics.exact(title: "  SONG   TITLE ", artist: " artist ", duration: 180)
        let sharedRequests = await fixture.requests
        let cancellations = await fixture.cancellations
        precondition(active?.id == 1 && cached?.id == 1 && sharedRequests == 1 && cancellations == 0,
                     "Provisional and actual recording lookups must share their in-flight request and positive cache")

        _ = try await lyrics.exact(title: "Song Title", artist: "Artist", duration: 180.125)
        _ = try await lyrics.exact(title: "Song Title", artist: "Artist", duration: 180, useCache: false)
        let separateRequests = await fixture.requests
        precondition(separateRequests == 3, "Different media durations and explicit diagnostics must fetch independently")

        for _ in 0..<2 {
            do {
                _ = try await lyrics.exact(title: "Unavailable", artist: "Artist", duration: 180)
                preconditionFailure("An HTTP 500 must be reported to the caller")
            } catch let error as URLError { precondition(error.code == .badServerResponse) }
            let miss = try await lyrics.exact(title: "Missing", artist: "Artist", duration: 180)
            precondition(miss == nil)
        }
        let afterMisses = await fixture.requests
        precondition(afterMisses == 9, "Failed and unmatched requests must remain eligible for retry")

        await fixture.setHeld(true)
        let abandoned = Task { try await lyrics.exact(title: "Song Title", artist: "Artist", duration: 181) }
        try await fixture.waitForRequests(10)
        abandoned.cancel()
        do {
            _ = try await abandoned.value
            preconditionFailure("An abandoned lookup returned a result")
        } catch is CancellationError {}
        try await fixture.waitForOrphanCancellation()
        print("PASS: exact lyrics reuse, canonical metadata and duration, live bypass, and orphan cancellation")
    }
}
