@preconcurrency import AVFoundation
import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

// Authenticate the short-lived test CA inside this process. Release builds
// use the system trust store and never compile this delegate.
final class NavidromeLiveTrust: NSObject, URLSessionDelegate, Sendable {
    private let certificate = ProcessInfo.processInfo.environment["SYLLUME_NAVIDROME_CA_FILE"].flatMap {
        try? Data(contentsOf: URL(fileURLWithPath: $0))
    }

    static func session(_ configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        URLSession(configuration: configuration, delegate: Self(), delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.host == "localhost", space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust, let certificate,
              let root = SecCertificateCreateWithData(nil, certificate as CFData),
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, space.host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            print("Cannot prepare the TLS trust challenge for the isolated Navidrome server.")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            print("Isolated Navidrome certificate verification returned Security code \(trustError.map { CFErrorGetCode($0) } ?? 0).")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@main
struct NavidromeLiveProbe {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func main() async {
        do {
            try await run()
        } catch {
            let native = error as NSError
            print("Navidrome integration failed (\(native.domain) \(native.code)): \(error.localizedDescription)")
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["SYLLUME_NAVIDROME_URL"],
              let address = URLComponents(string: server), address.host == "localhost",
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
        print("PASS: Swift authenticated with Navidrome over HTTPS")
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
        let catalogueEntry = LibraryEntry(id: "navidrome-fixture", title: title, subtitle: artist,
                                          url: URL(string: "https://www.youtube.com/watch?v=M7lc1UVf-VE")!,
                                          duration: duration)
        guard let song = SyncedYouTubeSong(catalogueEntry) else {
            throw Failure(message: "Could not construct the selected catalogue recording.")
        }
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
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let streamSession = NavidromeLiveTrust.session()
        defer { streamSession.finishTasksAndInvalidate() }
        let (streamed, streamResponse) = try await streamSession.data(from: streamURL)
        guard (streamResponse as? HTTPURLResponse)?.statusCode == 200, streamed == original else {
            throw Failure(message: "The HTTPS raw stream differs from the exact indexed file.")
        }
        let download = try await service.download(selected)
        defer { try? FileManager.default.removeItem(at: download) }
        let verification = try await AudioIntegrity.verifyDownload(AVURLAsset(url: download),
                                                                  expected: duration, previous: nil)
        guard verification.digest == Data(SHA256.hash(data: original)),
              try Data(contentsOf: download) == original else {
            throw Failure(message: "The Navidrome download differs from the exact indexed file.")
        }
        print("PASS: HTTPS ping, real search returned \(tracks.count) tracks, one exact Navidrome candidate, byte-identical raw stream and fully decoded download (\(original.count) bytes, \(verification.duration)s)")

        let rejected = try NavidromeAccount(server: server, username: username, password: password + "-wrong")
        let rejection = await service.streamingSource(.navidrome, song: song, account: rejected)
        let credentialsFailure = DiagnosticProblem(code: .reauthorize, nativeCode: 40)
        guard rejection.candidates.isEmpty, rejection.problem == credentialsFailure else {
            let evidence = rejection.problem?.detail ?? "no error"
            throw Failure(message: "Expected Subsonic 40 to remain a credentials error, got \(evidence).")
        }
        let rejectedURL = try rejected.endpoint("download", parameters: [.init(name: "id", value: exact.id)])
        let unauthorized = DownloadAudioCandidate(url: rejectedURL, title: selected.title, artist: selected.artist,
                                                  duration: selected.duration, format: selected.format,
                                                  bitrate: selected.bitrate, source: selected.source)
        do {
            let rejectedFile = try await service.download(unauthorized)
            try? FileManager.default.removeItem(at: rejectedFile)
            throw Failure(message: "The downloader accepted an unauthorized response as audio.")
        } catch let error as NavidromeError {
            guard DiagnosticProblem.classify(error) == credentialsFailure else { throw error }
        }
        print("PASS: search and download rejected incorrect credentials with Subsonic code 40, classified as reauthorize")
    }
}
