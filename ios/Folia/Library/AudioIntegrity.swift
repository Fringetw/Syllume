@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

enum AudioIntegrity {
    static func streamingAsset(for candidate: DownloadAudioCandidate) -> AVURLAsset {
        let url = candidate.streamingURL ?? candidate.url
        // YouTube's CDN serves M4A streams from extensionless endpoints.
        // Use the selected rendition's known container to initialize AVFoundation.
        let options: [String: Any]? = candidate.diagnosticSource == .youtube && candidate.format == "m4a"
            ? [AVURLAssetOverrideMIMETypeKey: "audio/mp4"] : nil
        return AVURLAsset(url: url, options: options)
    }

    static func inspect(_ url: URL, expected: Double, decode: Bool) async throws -> Double {
        try await inspect(AVURLAsset(url: url), expected: expected, decode: decode,
                          deadline: url.isFileURL ? nil : .seconds(12))
    }

    static func inspect(_ asset: AVURLAsset, expected: Double, decode: Bool, deadline: Duration?) async throws -> Double {
        let clock = ContinuousClock()
        let decodeDeadline = deadline.map { clock.now.advanced(by: $0) }
        let timer = deadline.map { time in
            Task {
                try? await Task.sleep(for: time)
                if !Task.isCancelled { asset.cancelLoading() }
            }
        }
        defer { timer?.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await verify(asset, expected: expected, decode: decode, deadline: decodeDeadline)
            } onCancel: { asset.cancelLoading() }
        } catch {
            try Task.checkCancellation()
            if let decodeDeadline, clock.now >= decodeDeadline { throw DiagnosticProblem(code: .timeout) }
            throw error
        }
    }

    private static func verify(_ asset: AVURLAsset, expected: Double, decode: Bool,
                               deadline: ContinuousClock.Instant?) async throws -> Double {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw DiagnosticProblem(code: .invalidMedia, mediaIssue: .missingAudioTrack)
        }
        guard try await asset.loadTracks(withMediaType: .video).isEmpty else {
            throw DiagnosticProblem(code: .invalidMedia, mediaIssue: .unexpectedVideoTrack)
        }
        guard try await asset.load(.isPlayable) else {
            throw DiagnosticProblem(code: .invalidMedia, mediaIssue: .notPlayable)
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw DiagnosticProblem(code: .invalidMedia, mediaIssue: .durationUnavailable)
        }
        guard DownloadSongMatch.sameDuration(duration, expected) else {
            throw DiagnosticProblem(code: .invalidMedia, mediaIssue: .durationMismatch)
        }
        try Task.checkCancellation()
        if decode {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
            reader.add(output)
            guard reader.startReading() else { throw CocoaError(.fileReadCorruptFile) }
            var first = Double.infinity, end = 0.0, decoded = 0.0
            while let sample = output.copyNextSampleBuffer() {
                if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
                if let deadline, ContinuousClock.now >= deadline {
                    reader.cancelReading()
                    throw DiagnosticProblem(code: .timeout)
                }
                let stamp = sample.presentationTimeStamp.seconds
                let sampleDuration = sample.duration.seconds
                let rate = sample.formatDescription.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 0
                let length = rate > 0 ? Double(sample.numSamples) / rate : sampleDuration
                guard stamp.isFinite, length.isFinite, length > 0 else { reader.cancelReading(); throw CocoaError(.fileReadCorruptFile) }
                first = min(first, stamp); end = max(end, stamp + length); decoded += length
            }
            let slack = min(1.0, max(0.15, duration * 0.003))
            guard reader.status == .completed, first <= slack, end >= duration - slack,
                  decoded >= duration - slack else {
                throw PlatformError.message("音檔無法完整解碼，已略過這個來源。")
            }
        }
        return duration
    }
}
