import Foundation

enum PlaylistTransferChecks {
    private final class Started: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.lock(); value = true; lock.unlock() }
        func read() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func run(audio: URL) async throws {
        guard let value = ProcessInfo.processInfo.environment["FOLIA_AUDIO_TEST_URL"], let base = URL(string: value) else {
            preconditionFailure("Missing loopback audio test server")
        }
        let permitted: @Sendable (URL) -> Bool = {
            $0.scheme == "http" && $0.host == "127.0.0.1" && $0.port == base.port &&
                ["/audio", "/redirect", "/foreign-redirect", "/html", "/oversized", "/slow"].contains($0.path)
        }
        let song = SubtitleSong(id: "fixture", source: "fixture", title: "潮汐之間", artist: "Folia", durationMs: 30_000)
        func source(_ path: String) -> DownloadableAudio {
            .init(provider: "netease", song: song, url: base.appending(path: path), fileExtension: "m4a", qualityRank: 20, bitrate: 0)
        }
        for path in ["audio", "redirect"] {
            let transfer = PlaylistAudioTransfer(source: source(path), wifiOnly: false, allowedURL: permitted, progress: { _ in })
            let file = try await transfer.run()
            defer { try? FileManager.default.removeItem(at: file) }
            let downloaded = try Data(contentsOf: file), expected = try Data(contentsOf: audio)
            precondition(downloaded == expected)
            let inspected = try await InspectedPlaylistAudio.inspect(file, source: source(path))
            precondition(abs(inspected.duration - 30) < 2 && !inspected.quality.isEmpty)
            let tooLong = DownloadableAudio(provider: "netease",
                song: SubtitleSong(id: "fixture", source: "fixture", title: "full song", artist: "Folia", durationMs: 300_000),
                url: base.appending(path: path), fileExtension: "m4a", qualityRank: 20, bitrate: 0)
            do {
                _ = try await InspectedPlaylistAudio.inspect(file, source: tooLong)
                preconditionFailure("A 30-second clip must not become a 5-minute full song")
            } catch { precondition(error as? PlaylistAudioError == .incomplete) }
        }
        for path in ["html", "foreign-redirect", "oversized"] {
            let transfer = PlaylistAudioTransfer(source: source(path), wifiOnly: false, allowedURL: permitted, progress: { _ in })
            do {
                let file = try await transfer.run()
                try? FileManager.default.removeItem(at: file)
                preconditionFailure("Invalid response became a downloaded song: " + path)
            } catch { }
        }
        let started = Started()
        let transfer = PlaylistAudioTransfer(source: source("slow"), wifiOnly: false, allowedURL: permitted,
                                             progress: { _ in started.mark() })
        let running = Task { try await transfer.run() }
        for _ in 0..<100 {
            if started.read() { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(started.read(), "Cancellation must interrupt a real response already in progress")
        running.cancel()
        do {
            let file = try await running.value
            try? FileManager.default.removeItem(at: file)
            preconditionFailure("Cancelled transfer returned a file")
        } catch is CancellationError { }
        let blocked = PlaylistAudioTransfer(source: source("audio"), wifiOnly: false, progress: { _ in })
        do { _ = try await blocked.run(); preconditionFailure("Production URL policy accepted a local HTTP URL") }
        catch { precondition(error as? PlaylistAudioError == .invalidFile) }
        print("PASS: real HTTP audio transfer, full-file duration, redirect policy, rejection and cancellation")
    }
}
