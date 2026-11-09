@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

enum AudioIntegrity {
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
        return try await withTaskCancellationHandler {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let video = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration).seconds
            guard try await asset.load(.isPlayable), let track = tracks.first, video.isEmpty,
                  DownloadSongMatch.sameDuration(duration, expected) else {
                throw PlatformError.message("音源沒有完整音軌，或長度與所選版本不符。")
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
                    if let decodeDeadline, clock.now >= decodeDeadline {
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
        } onCancel: { asset.cancelLoading() }
    }
}
