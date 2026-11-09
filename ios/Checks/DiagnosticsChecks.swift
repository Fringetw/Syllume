import Foundation

enum DiagnosticsChecks {
    static func run() async throws {
        let quota = Data(#"{"error":{"errors":[{"reason":"quotaExceeded","message":"secret-token"}]}}"#.utf8)
        let expiry = Data(#"{"error":"invalid_grant","error_description":"secret-cookie"}"#.utf8)
        precondition(DiagnosticProblem.googleHTTP(403, body: quota).code == .quota)
        precondition(DiagnosticProblem.googleHTTP(403, body: Data()).code == .permission)
        precondition(DiagnosticProblem.googleHTTP(429, body: Data()).code == .rateLimit)
        precondition(DiagnosticProblem.googleHTTP(400, body: expiry).code == .reauthorize)
        precondition(DiagnosticProblem.classify(URLError(.notConnectedToInternet)).code == .offline)
        precondition(DiagnosticProblem.classify(URLError(.timedOut)).code == .timeout)
        precondition(DiagnosticProblem.classify(SubtitleReadError("region-restricted")).code == .region)
        precondition(DiagnosticProblem.classify(SubtitleReadError("verification-required")).code == .verification)

        let start = ContinuousClock.now
        let operations: [@Sendable () async -> Int?] = [
            { @Sendable in try? await Task.sleep(for: .seconds(10)); return nil },
            { @Sendable in nil },
            { @Sendable in 187 }
        ]
        let first = try await PlaybackLookup.firstAvailable(operations)
        precondition(first == 187 && start.duration(to: .now) < .seconds(3))
        do {
            _ = try await PlaybackLookup.within(.milliseconds(15)) { try await Task.sleep(for: .seconds(10)) }
            preconditionFailure("A nonresponding source was treated as available")
        } catch { precondition(DiagnosticProblem.classify(error).code == .timeout) }

        let userAgentRestricted = #"<script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"UNPLAYABLE","reason":"not available in your country"},"videoDetails":{"videoId":"RCXjG2tsojs"}};</script>"#
        do {
            _ = try YouTubeCaptionDecoders.tracks(userAgentRestricted, videoID: "RCXjG2tsojs")
            preconditionFailure("A regional restriction was treated as a valid player")
        } catch { precondition(DiagnosticProblem.classify(error).code == .region) }

        let frame = #"{"callStacks":[{"callStackRootFrames":[{"binaryName":"Folia","offsetIntoBinaryTextSegment":4022,"address":948838,"path":"secret-server"},{"binaryName":"secret-cookie","offsetIntoBinaryTextSegment":42}]}]}"#
        let offsets = DiagnosticSystemTrace.foliaOffsets(Data(frame.utf8))
        precondition(offsets == [4022])
        let now = Date()
        let checks = [
            DiagnosticCheck("google.fixture", "OAuth 回應解析", .passed, .simulatedInput, since: now, metrics: ["omitted": .infinity]),
            DiagnosticCheck("google.api", "真實歌單", .unverifiable, .liveNetwork, since: now,
                            problem: DiagnosticProblem.googleHTTP(403, body: quota))
        ]
        let result = DiagnosticResult(area: .google, checks: checks, since: now)
        precondition(result.state == .partial)
        let report = DiagnosticReport(schemaVersion: 1, id: UUID(), appVersion: "0.3.11", build: "22",
            operatingSystem: "CI", deviceModel: "CI", environment: .ciFixture, startedAt: now, endedAt: Date(),
            connection: .unknown, stopReason: nil, requestedAreas: [.google, .device], results: [result], events: [],
            systemTraces: [DiagnosticSystemTrace(kind: .crash, foliaOffsets: offsets)],
            reproduction: ["使用模擬 HTTP 403"], notCovered: ["真實歌單"])
        precondition(report.retryAreas == [.google, .device])
        let json = try report.json()
        let serialized = String(decoding: json, as: UTF8.self)
        for secret in ["secret-token", "secret-cookie", "secret-server", "948838", "omitted"] {
            precondition(!serialized.contains(secret) && !report.text.contains(secret))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(DiagnosticReport.self, from: json)
        precondition(roundTrip.environment == .ciFixture && roundTrip.results.first?.checks.last?.problem?.httpStatus == 403)
        precondition(roundTrip.results.first?.checks.last?.checkpoints == ["Folia.Diagnostics", "google.api"])
        if let path = ProcessInfo.processInfo.environment["FOLIA_DIAGNOSTICS_FIXTURE_REPORT"] {
            try json.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("PASS: diagnostics evidence, OAuth/HTTP errors, playback deadlines, caption restrictions, and private report encoding (fixture)")
    }
}
