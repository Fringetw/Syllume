import Foundation

enum StreamingSourceChecks {
    private actor ProviderProbe {
        var calls: [DiagnosticSource: Int] = [:]
        private var fallbackReleased = false
        private var fallbackWaiting: CheckedContinuation<Void, Never>?

        func resolve(_ source: DiagnosticSource) async -> AudioDownloadService.SourceAttempt {
            calls[source, default: 0] += 1
            if source == .qq && !fallbackReleased {
                await withCheckedContinuation { fallbackWaiting = $0 }
            }
            let length: Double = source == .netease ? 30 : 240
            let candidate = DownloadAudioCandidate(url: URL(string: "https://example.com/\(source.rawValue).m4a")!,
                title: "Fixture", artist: "Artist", duration: length, format: "m4a", bitrate: 128_000, source: source.title)
            return .init(source: source, candidates: [candidate], problem: nil, elapsedMs: 0)
        }

        func releaseFallback() {
            fallbackReleased = true
            fallbackWaiting?.resume()
            fallbackWaiting = nil
        }
    }

    static func run() async throws {
        let probe = ProviderProbe()
        let lookup = AudioDownloadService.SourceLookup(sources: [.netease, .qq], budgetMs: 3_000) {
            await probe.resolve($0)
        }
        let first = await lookup.next()
        precondition(first?.source == .netease && first?.candidates.first?.duration == 30,
                     "A fast candidate must be offered while the alternate provider is still waiting")

        // The first candidate is too short, so the resolver consumes the already-started alternate.
        await probe.releaseFallback()
        let fallback = await lookup.next()
        let exhausted = await lookup.next()
        let calls = await probe.calls
        precondition(fallback?.source == .qq && fallback?.candidates.first?.duration == 240)
        precondition(exhausted == nil && calls == [.netease: 1, .qq: 1],
                     "Fallback must consume an existing reply rather than starting another query")

        let timeout = AudioDownloadService.SourceLookup(sources: [.qq], budgetMs: 10) { source in
            try? await Task.sleep(for: .seconds(30))
            return .init(source: source, candidates: [], problem: nil, elapsedMs: 0)
        }
        let reply = await timeout.next()
        let end = await timeout.next()
        precondition(reply?.source == .qq && reply?.problem?.code == .timeout && end == nil,
                     "A stalled provider must hit the lookup deadline and terminate the result stream")
        print("PASS: provider queries are shared across candidate fallback and bounded by a common deadline")
    }
}
