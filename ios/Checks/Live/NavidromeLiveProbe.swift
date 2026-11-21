@preconcurrency import AVFoundation
import CryptoKit
import Foundation

@main
struct NavidromeLiveProbe {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["SYLLUME_NAVIDROME_URL"],
              let address = URLComponents(string: server), address.host == "127.0.0.1",
              let username = environment["SYLLUME_NAVIDROME_USER"],
              let password = environment["SYLLUME_NAVIDROME_PASSWORD"],
              let path = environment["SYLLUME_NAVIDROME_EXACT_FILE"] else {
            throw Failure(message: "The isolated Navidrome server and owned audio sample must be provided.")
        }
        let title = "潮汐之間"
        let artist = "Syllume Fixture"
        let account = try NavidromeAccount(server: server, username: username, password: password)
        let client = NavidromeClient(account: account)
        try await client.ping()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(45)
        var tracks: [Track]
        repeat {
            tracks = try await client.search(title, limit: 20)
            if tracks.count >= 3 { break }
            try await Task.sleep(for: .seconds(2))
        } while clock.now < deadline

        guard let exact = tracks.first(where: { $0.title == title && $0.artist == artist }),
              let duration = exact.duration,
              tracks.contains(where: { $0.title == title && $0.artist != artist && $0.duration == duration }),
              tracks.contains(where: { $0.title == title + " (Live)" && $0.artist == artist }) else {
            throw Failure(message: "Navidrome did not return the exact recording and both decoys (\(tracks.count) results).")
        }
        let song = SyncedYouTubeSong(id: "navidrome-fixture", videoID: "M7lc1UVf-VE", title: title,
                                     artist: artist, duration: duration)
        let service = AudioDownloadService(authorizedMediaProviders: [])
        let candidates = try await service.candidates(for: song, account: account)
        guard candidates.count == 1, let selected = candidates.first,
              selected.diagnosticSource == .navidrome, selected.recording?.id == exact.id,
              let streamURL = selected.streamingURL else {
            throw Failure(message: "Only the matching Navidrome recording should be selected for download.")
        }
        let stream = await service.streamingSource(.navidrome, song: song, account: account)
        guard stream.problem == nil, stream.candidates.map({ $0.recording?.id }) == [exact.id] else {
            throw Failure(message: "Streaming selected a different recording or failed to find it.")
        }
        let streamDuration = try await AudioIntegrity.inspect(streamURL, expected: duration, decode: false)
        let download = try await service.download(selected)
        defer { try? FileManager.default.removeItem(at: download) }
        let verification = try await AudioIntegrity.verifyDownload(AVURLAsset(url: download),
                                                                  expected: duration, previous: nil)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        guard verification.digest == Data(SHA256.hash(data: original)),
              try Data(contentsOf: download) == original else {
            throw Failure(message: "The Navidrome download differs from the exact indexed file.")
        }
        print("PASS: HTTPS ping, real search returned \(tracks.count) tracks, one exact Navidrome candidate, raw stream \(streamDuration)s, byte-identical and fully decoded download (\(original.count) bytes)")

        let rejected = try NavidromeAccount(server: server, username: username, password: password + "-wrong")
        let rejection = await service.streamingSource(.navidrome, song: song, account: rejected)
        guard rejection.candidates.isEmpty, rejection.problem == DiagnosticProblem(code: .reauthorize, nativeCode: 40) else {
            let evidence = rejection.problem?.detail ?? "no error"
            throw Failure(message: "Expected Subsonic 40 to remain a credentials error, got \(evidence).")
        }
        print("PASS: Navidrome rejected incorrect credentials with Subsonic code 40, classified as reauthorize")
    }
}
