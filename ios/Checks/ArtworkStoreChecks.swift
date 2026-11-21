import Foundation

enum ArtworkStoreChecks {
    private actor TransportProbe {
        let image: Data
        private(set) var requests = 0
        private(set) var cancellations = 0
        private var responseReady = false

        init(image: Data) { self.image = image }

        func fetch() async -> YouTubeArtworkStore.ImageResponse? {
            requests += 1
            do {
                while !responseReady { try await Task.sleep(for: .milliseconds(10)) }
                try Task.checkCancellation()
                return .init(data: image, canCache: true)
            } catch {
                cancellations += 1
                return nil
            }
        }

        func releaseResponse() { responseReady = true }
    }

    static func run() async throws {
        let directory = URL.temporaryDirectory.appending(path: "SyllumeArtworkCheck-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGNM37OWARtgwio6aCUAbbEB4B0QKzMAAAAASUVORK5CYII=")!
        let probe = TransportProbe(image: image)
        let store = YouTubeArtworkStore(directory: directory, fetch: { _ in await probe.fetch() })
        let videoID = "M7lc1UVf-VE"
        let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/default.jpg")!
        let source = SongArtworkSource(file: nil, videoID: videoID, candidates: [url])

        let first = Task { await store.image(for: source) }
        let second = Task { await store.image(for: source) }
        try await waitFor("Both consumers should share a single artwork fetch") {
            let subscribers = await store.subscribers(for: url)
            let requests = await probe.requests
            return subscribers == 2 && requests == 1
        }
        first.cancel()
        try await waitFor("Canceling one consumer must detach it from the shared fetch") {
            await store.subscribers(for: url) == 1
        }
        let canceledFirst = await first.value
        let cancellationsAfterFirst = await probe.cancellations
        precondition(canceledFirst == nil && cancellationsAfterFirst == 0,
                     "Canceling one consumer cannot interrupt another consumer's network transfer")

        second.cancel()
        try await waitFor("The last canceled consumer must stop the artwork transport") {
            let subscribers = await store.subscribers(for: url)
            let cancellations = await probe.cancellations
            return subscribers == 0 && cancellations == 1
        }
        let canceledSecond = await second.value
        precondition(canceledSecond == nil)

        let retry = Task { await store.image(for: source) }
        try await waitFor("A later request must not reuse the canceled artwork fetch") { await probe.requests == 2 }
        await probe.releaseResponse()
        let received = await retry.value
        precondition(received == image)
        let reopened = YouTubeArtworkStore(directory: directory, fetch: { _ in
            preconditionFailure("A successful retry should be available from the artwork disk cache")
        })
        let cached = await reopened.image(for: source)
        precondition(cached == image)
        print("PASS: artwork shares URL requests, cancels orphan transfers, and caches a fresh retry")
    }

    private static func waitFor(_ message: String, condition: () async -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(4))
        while ContinuousClock().now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure(message)
    }
}
