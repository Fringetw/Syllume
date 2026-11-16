@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CryptoKit
import Darwin
import Foundation

enum AudioIntegrity {
    static func inspect(_ url: URL, expected: Double, decode: Bool) async throws -> Double {
        try await inspect(AVURLAsset(url: url), expected: expected, decode: decode,
                          deadline: url.isFileURL ? nil : .seconds(12))
    }

    static func inspect(_ asset: AVURLAsset, expected: Double?, decode: Bool, deadline: Duration?) async throws -> Double {
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

    static func verifyDownload(_ asset: AVURLAsset, expected: Double?, previous: DownloadVerification?) async throws -> DownloadVerification {
        try Task.checkCancellation()
        let url = asset.url
        let stamp = try fileStamp(url)
        if let previous, previous.file == stamp {
            try checkDuration(previous.duration, expected: expected)
            return previous
        }

        let digest = try await downloadDigest(url)
        let changed = DiagnosticProblem(code: .invalidMedia, mediaIssue: .changedDownload)
        guard try fileStamp(url) == stamp else { throw changed }

        let duration: Double
        if let previous {
            guard digest == previous.digest else { throw changed }
            duration = previous.duration
            try checkDuration(duration, expected: expected)
        } else {
            duration = try await inspect(asset, expected: expected, decode: true, deadline: nil)
        }
        guard try fileStamp(url) == stamp else { throw changed }
        return DownloadVerification(file: stamp, digest: digest, duration: duration)
    }

    static func hasDownloadStamp(_ url: URL, _ verification: DownloadVerification) -> Bool {
        (try? fileStamp(url)) == verification.file
    }

    private static func fileStamp(_ url: URL) throws -> DownloadVerification.FileStamp {
        var attributes = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &attributes)
        }
        guard result == 0, (attributes.st_mode & UInt16(S_IFMT)) == UInt16(S_IFREG), attributes.st_size > 0 else {
            throw DiagnosticProblem(code: .invalidMedia, mediaIssue: .notPlayable)
        }
        return DownloadVerification.FileStamp(device: attributes.st_dev, inode: attributes.st_ino, size: attributes.st_size,
            modificationSeconds: attributes.st_mtimespec.tv_sec, modificationNanoseconds: attributes.st_mtimespec.tv_nsec,
            changeSeconds: attributes.st_ctimespec.tv_sec, changeNanoseconds: attributes.st_ctimespec.tv_nsec)
    }

    private static func downloadDigest(_ url: URL) async throws -> Data {
        let reader = Task.detached(priority: .utility) {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = SHA256()
            while let chunk = try file.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                digest.update(data: chunk)
            }
            try Task.checkCancellation()
            return Data(digest.finalize())
        }
        return try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
    }

    private static func checkDuration(_ duration: Double, expected: Double?) throws {
        guard duration.isFinite, duration > 0 else {
            throw DiagnosticProblem(code: .invalidMedia, mediaIssue: .durationUnavailable)
        }
        if let expected, !DownloadSongMatch.sameDuration(duration, expected) {
            throw DiagnosticProblem(code: .invalidMedia, mediaIssue: .durationMismatch)
        }
    }

    private static func verify(_ asset: AVURLAsset, expected: Double?, decode: Bool,
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
        try checkDuration(duration, expected: expected)
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
